module wedepend.depcalc;

import std.stdio;
import std.array;
import std.conv;
import std.algorithm;
import std.string : format, splitLines, join, startsWith;

import dparse.parser;
import dparse.lexer;
import dparse.ast;
import dparse.formatter;
import dparse.rollback_allocator;

ubyte[] readInputFile(string inputFile)
{
    File f = File(inputFile);
    ubyte[]bytes = uninitializedArray!(ubyte[])(to!size_t(f.size));
    f.rawRead(bytes);
    if (bytes[0 .. 3] == "\xef\xbb\xbf") {
        return bytes[3 .. $];
    }
    return bytes;
}

struct ConditionalDeclarations
{
    string versionName;
    bool decidedCondition;
    bool inTrueDeclaration;
}

class CopySourcePrinter : ASTVisitor{

    override void visit(const SingleImport expr) {
        bool first = true;
        foreach (token; expr.identifierChain.identifiers) {
            if (!first) {
                output.write('.');
            }
            output.write(token.text);
            first = false;
        }
        output.write('\n');
    }

    override void visit(const Unittest dec)
    {
        if (!includeUnittest) {
            return;
        }

        dec.accept(this);
    }

    override void visit(const ConditionalStatement visitor)
    {
        condDecls ~= ConditionalDeclarations();
        scope (exit) condDecls = condDecls[0..$-1];

        auto condDecl = &condDecls[$-1];

        assert(visitor.compileCondition !is null);
        this.visit(visitor.compileCondition);

        if (!condDecl.decidedCondition || condDecl.inTrueDeclaration) {
            if (visitor.trueStatement !is null) {
                this.visit(visitor.trueStatement);
            }
        }

        if (!condDecl.decidedCondition || !condDecl.inTrueDeclaration) {
            if (visitor.falseStatement !is null) {
                this.visit(visitor.falseStatement);
            }
        }
    }

    override void visit(const ConditionalDeclaration visitor)
    {
        condDecls ~= ConditionalDeclarations();
        scope (exit) condDecls = condDecls[0..$-1];

        assert(visitor.compileCondition !is null);
        this.visit(visitor.compileCondition);

        auto condDecl = &condDecls[$-1];

        if (!condDecl.decidedCondition || condDecl.inTrueDeclaration) {
            foreach (decl; visitor.trueDeclarations) {
                if (decl !is null) {
                    this.visit(decl);
                }
            }
        }

        if (!condDecl.decidedCondition || !condDecl.inTrueDeclaration) {
            foreach (decl; visitor.falseDeclarations) {
                if (decl !is null) {
                    this.visit(decl);
                }
            }
        }
    }

    override void visit(const VersionCondition visitor)
    {
        //stderr.writefln("  version condition len %d at %d: %s (%s)", condDecls.length, visitor.token.line, visitor.token.text, str(visitor.token.type));
        auto condDecl = &condDecls[$-1];

        auto tokenStr = str(visitor.token.type);
        if (tokenStr == "unittest") {
            condDecl.decidedCondition = true;
            condDecl.versionName = "unittest";
            condDecl.inTrueDeclaration = includeUnittest;
        } else if (tokenStr == "identifier") {
            condDecl.versionName = visitor.token.text;
            if (versions.length > 0) {
                // The user gave us a set of versions, we assume this set is complete and we can decide on the versions supported
                condDecl.decidedCondition = true;
                foreach (ver; versions) {
                    if (ver == condDecl.versionName) {
                        condDecl.inTrueDeclaration = true;
                        break;
                    }
                }
            }
        }

        // TODO: handle other version definitions (assert, debug_assert, etc.)
    }

    override void visit(const StaticIfCondition visitor)
    {
        if (visitor.assignExpression is null) {
            return;
        }

        if (visitor.assignExpression.tokens.length != 1) {
            return;
        }

        auto token = visitor.assignExpression.tokens[0];

        if (str(token.type) == "intLiteral") {
            auto condDecl = &condDecls[$-1];

            if (token.text == "0") {
                condDecl.decidedCondition = true;
                condDecl.inTrueDeclaration = false;
            } else if (token.text == "1") {
                condDecl.decidedCondition = true;
                condDecl.inTrueDeclaration = true;
            }
        }
    }

    alias visit = ASTVisitor.visit;

    string fileName;
    File output;
    int unittestCount = 0;
    bool includeUnittest;
    ConditionalDeclarations[] condDecls;
    string[] versions;
}

void noMsg(string filename, size_t line, size_t column, string message, bool error) {
}

void errorMsg(string filename, size_t line, size_t column, string message, bool error) {
    if (!error) {
        return;
    }

    stderr.writefln("%s(%d:%d)[warn]: %s", filename, line, column, message);
}

private string chainToString(const IdentifierChain chain) {
    if (chain is null) return "";
    auto a = appender!string;
    foreach (i, t; chain.identifiers) {
        if (i > 0) a.put('.');
        a.put(t.text);
    }
    return a.data;
}

class ScopeInfoVisitor : ASTVisitor {
    File output;
    string[] templateStack;   // outermost first; non-empty => inside a template

    // Stack of nested containers. Each entry is (kind, name). Pushed on
    // FunctionDeclaration / StructDeclaration / ClassDeclaration /
    // InterfaceDeclaration / UnionDeclaration / BlockStatement / Unittest.
    // The innermost (top of stack) determines whether a `scoped` import
    // lives inside a body that hdrgen elides:
    //   func, block, unittest  → elided in .di (safe for Bazel implementation_deps)
    //   struct, class, interface, union → preserved in .di (must be in Bazel deps)
    // The name field is the enclosing decl name, or "_" for anonymous
    // (e.g. raw blocks, unittests).
    struct Container { string kind; string name; }
    Container[] containerStack;

    // Depth of enclosing function/unittest BODIES (BlockStatement under executable
    // code). hdrgen ELIDES these from the .di, so identifier references at
    // bodyDepth>0 do NOT leak through this file's interface. References at
    // bodyDepth==0 (return/param/field types, template params/constraints,
    // manifest-constant initializers, default args) DO appear in the .di and so
    // propagate to consumers. Used to emit `ifaceref` for interface-position
    // symbol uses only.
    int bodyDepth;

    // True while visiting a `public import`/`export import` declaration. Such
    // imports RE-EXPORT their symbols to consumers regardless of local use, so
    // they must always propagate — emitted as a `public <mod>` marker that the
    // scanner uses to exempt the module from usage-based reclassification.
    bool inPublicDecl;

    alias visit = ASTVisitor.visit;

    private bool isFileScope() const {
        return templateStack.length == 0 && containerStack.length == 0;
    }

    private string outerTemplate() const {
        return templateStack.length > 0 ? templateStack[0] : "";
    }

    private void emitImport(string mod) {
        if (mod.length == 0) return;
        if (templateStack.length > 0) {
            output.writefln("tmpl\t%s\t%s", outerTemplate, mod);
        } else if (containerStack.length > 0) {
            // Find the innermost NAMED container — skip past anonymous blocks
            // (function-body braces, if/while/with blocks). The kind we report
            // is the first non-block; the name comes from there. A bare block
            // with no named ancestor (very unusual at module level) reports as
            // `block / _`.
            string kind = "block";
            string name = "_";
            foreach_reverse (c; containerStack) {
                if (c.kind != "block") {
                    kind = c.kind;
                    name = c.name;
                    break;
                }
            }
            output.writefln("scoped\t%s\t%s\t%s", kind, name, mod);
        } else {
            output.writefln("top\t%s", mod);
        }
        if (inPublicDecl) {
            output.writefln("public\t%s", mod);
        }
    }

    // A `public`/`export` qualifier on an import declaration makes it a
    // re-export. Mark inPublicDecl for the duration of this Declaration's accept
    // so emitImport tags its modules. A Declaration wrapping an import contains
    // only that import (no nested decls), so the flag can't leak.
    override void visit(const Declaration node) {
        bool pub = false;
        foreach (a; node.attributes) {
            if (a.attribute.type == tok!"public" || a.attribute.type == tok!"export") {
                pub = true;
                break;
            }
        }
        bool saved = inPublicDecl;
        if (pub && node.importDeclaration !is null) inPublicDecl = true;
        scope(exit) inPublicDecl = saved;
        node.accept(this);
    }

    override void visit(const ImportDeclaration node) {
        foreach (si; node.singleImports) {
            if (si is null) continue;
            emitImport(chainToString(si.identifierChain));
        }
        if (node.importBindings !is null) {
            auto si = node.importBindings.singleImport;
            if (si !is null) {
                auto mod = chainToString(si.identifierChain);
                emitImport(mod);
                if (mod.length > 0) {
                    string[] syms;
                    foreach (b; node.importBindings.importBinds) {
                        if (b is null) continue;
                        auto t = b.left.text;
                        if (t.length > 0) syms ~= t;
                    }
                    if (syms.length > 0) {
                        output.writefln("binding\t%s\t%s", mod, syms.join(","));
                    }
                }
            }
        }
    }

    override void visit(const TemplateDeclaration node) {
        if (isFileScope) {
            output.writefln("template\t%s", node.name.text);
        }
        templateStack ~= node.name.text;
        containerStack ~= Container("template", node.name.text);
        scope(exit) {
            templateStack = templateStack[0 .. $-1];
            containerStack = containerStack[0 .. $-1];
        }
        node.accept(this);
    }

    override void visit(const FunctionDeclaration node) {
        const isTemplate = node.templateParameters !is null;
        const topLevel = isFileScope;
        if (isTemplate) {
            if (topLevel) output.writefln("template\t%s", node.name.text);
            templateStack ~= node.name.text;
        }
        containerStack ~= Container("func", node.name.text);
        scope(exit) {
            containerStack = containerStack[0 .. $-1];
            if (isTemplate) templateStack = templateStack[0 .. $-1];
        }
        node.accept(this);
    }

    override void visit(const StructDeclaration node) {
        const isTemplate = node.templateParameters !is null;
        const topLevel = isFileScope;
        if (isTemplate) {
            if (topLevel) output.writefln("template\t%s", node.name.text);
            templateStack ~= node.name.text;
        }
        containerStack ~= Container("struct", node.name.text);
        scope(exit) {
            containerStack = containerStack[0 .. $-1];
            if (isTemplate) templateStack = templateStack[0 .. $-1];
        }
        node.accept(this);
    }

    override void visit(const ClassDeclaration node) {
        const isTemplate = node.templateParameters !is null;
        const topLevel = isFileScope;
        if (isTemplate) {
            if (topLevel) output.writefln("template\t%s", node.name.text);
            templateStack ~= node.name.text;
        }
        containerStack ~= Container("class", node.name.text);
        scope(exit) {
            containerStack = containerStack[0 .. $-1];
            if (isTemplate) templateStack = templateStack[0 .. $-1];
        }
        node.accept(this);
    }

    override void visit(const InterfaceDeclaration node) {
        const isTemplate = node.templateParameters !is null;
        const topLevel = isFileScope;
        if (isTemplate) {
            if (topLevel) output.writefln("template\t%s", node.name.text);
            templateStack ~= node.name.text;
        }
        containerStack ~= Container("interface", node.name.text);
        scope(exit) {
            containerStack = containerStack[0 .. $-1];
            if (isTemplate) templateStack = templateStack[0 .. $-1];
        }
        node.accept(this);
    }

    override void visit(const UnionDeclaration node) {
        const isTemplate = node.templateParameters !is null;
        const topLevel = isFileScope;
        if (isTemplate) {
            if (topLevel) output.writefln("template\t%s", node.name.text);
            templateStack ~= node.name.text;
        }
        containerStack ~= Container("union", node.name.text);
        scope(exit) {
            containerStack = containerStack[0 .. $-1];
            if (isTemplate) templateStack = templateStack[0 .. $-1];
        }
        node.accept(this);
    }

    override void visit(const BlockStatement node) {
        containerStack ~= Container("block", "_");
        bodyDepth++;
        scope(exit) { containerStack = containerStack[0 .. $-1]; bodyDepth--; }
        node.accept(this);
    }

    override void visit(const Unittest node) {
        containerStack ~= Container("func", "_unittest");
        bodyDepth++;
        scope(exit) { containerStack = containerStack[0 .. $-1]; bodyDepth--; }
        node.accept(this);
    }

    // Emit every identifier referenced in an INTERFACE position (bodyDepth==0):
    // type names in signatures/fields, template params/constraints, manifest
    // initializers, default args — the identifiers that survive into the .di.
    // The Go/analysis side attributes each to its declaring module via the
    // top-level declares-index; a `top`/selective import propagates only if it
    // provides an ifaceref'd symbol. Body-only references (bodyDepth>0) are
    // omitted — they're elided from the .di and don't propagate.
    override void visit(const IdentifierOrTemplateInstance node) {
        if (bodyDepth == 0) {
            if (node.identifier.text.length > 0) {
                output.writefln("ifaceref\t%s", node.identifier.text);
            } else if (node.templateInstance !is null && node.templateInstance.identifier.text.length > 0) {
                output.writefln("ifaceref\t%s", node.templateInstance.identifier.text);
            }
        }
        node.accept(this);
    }

    // UDAs (`@attribute(...)`, `@foo!T`) annotate declarations and are PRESERVED
    // in the .di (hdrgen keeps attributes on signatures), so their symbol leaks
    // through this file's interface and must count as an ifaceref. The UDA name
    // is a bare Token on AtAttribute (not wrapped in IdentifierOrTemplateInstance),
    // so the visitor above never sees it — emit it here.
    override void visit(const AtAttribute node) {
        if (bodyDepth == 0) {
            if (node.identifier.text.length > 0) {
                output.writefln("ifaceref\t%s", node.identifier.text);
            } else if (node.templateInstance !is null && node.templateInstance.identifier.text.length > 0) {
                output.writefln("ifaceref\t%s", node.templateInstance.identifier.text);
            }
        }
        node.accept(this);
    }

    override void visit(const TemplateInstance node) {
        if (node.identifier.text.length > 0) {
            output.writefln("instance\t%s\t%s", outerTemplate, node.identifier.text);
        }
        node.accept(this);
    }

    override void visit(const FunctionCallExpression node) {
        // Skip explicit template calls foo!T(args) — the inner TemplateInstance already emits.
        if (node.templateArguments is null && node.unaryExpression !is null) {
            auto callee = extractCallee(node.unaryExpression);
            if (callee.length > 0) {
                output.writefln("call\t%s\t%s", outerTemplate, callee);
            }
        }
        node.accept(this);
    }

    private static string extractCallee(const UnaryExpression u) {
        if (u is null) return "";
        if (u.primaryExpression !is null) {
            auto p = u.primaryExpression;
            if (p.identifierOrTemplateInstance !is null) {
                auto iot = p.identifierOrTemplateInstance;
                if (iot.identifier.text.length > 0) return iot.identifier.text;
                if (iot.templateInstance !is null && iot.templateInstance.identifier.text.length > 0) {
                    return iot.templateInstance.identifier.text;
                }
            }
        }
        if (u.identifierOrTemplateInstance !is null) {
            auto iot = u.identifierOrTemplateInstance;
            if (iot.identifier.text.length > 0) return iot.identifier.text;
            if (iot.templateInstance !is null && iot.templateInstance.identifier.text.length > 0) {
                return iot.templateInstance.identifier.text;
            }
        }
        return "";
    }
}

void scopeInfo(File output, string inputFile) {
    StringCache cache = StringCache(StringCache.defaultBucketCount);
    LexerConfig config;
    config.fileName = inputFile;
    config.stringBehavior = StringBehavior.source;
    config.whitespaceBehavior = WhitespaceBehavior.skip;

    auto tokens = getTokensForParser(readInputFile(inputFile), config, &cache).array();
    if (tokens.length == 0) {
        stderr.writefln("scope-info: empty token stream for %s", inputFile);
        return;
    }

    RollbackAllocator rba;
    Module m = parseModule(tokens, inputFile, &rba, &noMsg);
    auto v = new ScopeInfoVisitor;
    v.output = output;
    v.visit(m);
}

void calcDependencies(File output, string inputFile, bool includeUnittest, bool verbose, string[] versions) {
    auto bytes = readInputFile(inputFile);

    StringCache cache = StringCache(StringCache.defaultBucketCount);

    LexerConfig config;
    config.fileName = inputFile;
    config.stringBehavior = StringBehavior.source;
    config.whitespaceBehavior = WhitespaceBehavior.skip;

    auto tokens = getTokensForParser(readInputFile(inputFile), config, &cache).array();
    if (tokens.length == 0){
        stderr.writefln("Oh Oh... the given file does not seem to contain any 'instrumentation point'.
            the dparser could not make sense out of this file; it's either not a d-file at all, or is inherently malformed.
            make sure it starts with a 'module' declaration.");
    }

    RollbackAllocator rba;
    Module m = parseModule(tokens, inputFile, &rba, verbose ? &errorMsg : &noMsg);
    auto printer = new CopySourcePrinter;
    printer.fileName = inputFile;
    printer.output = output;
    printer.includeUnittest = includeUnittest;
    printer.versions = versions;
    printer.visit(m);
}
