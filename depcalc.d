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

private bool isStringLiteralToken(const Token t) {
    return t.type == tok!"stringLiteral" || t.type == tok!"wstringLiteral" || t.type == tok!"dstringLiteral";
}

// Strips one layer of matching quote characters (and a trailing c/w/d
// string-literal suffix, if present) from a lexed string-literal token's
// raw text. Best-effort — doesn't unescape backslash sequences, since the
// UDA-name use case (module names, symbol names) never needs them.
private string stripStringQuotes(string s) {
    if (s.length < 2) return s;
    char q = s[0];
    if (q != '"' && q != '\'' && q != '`') return s;
    size_t end = s.length;
    if (end > 0 && (s[end - 1] == 'c' || s[end - 1] == 'w' || s[end - 1] == 'd')) end--;
    if (end < 2 || s[end - 1] != q) return s;
    return s[1 .. end - 1].idup;
}

// Descends through dparse's expression-precedence wrapper chain via the
// visitor pattern (so it doesn't need to know every intermediate node type
// between e.g. AssignExpression and PrimaryExpression) down to leaf
// PrimaryExpressions, collecting string-literal tokens. Used to read the
// argument to @GazelleEmits(["a", "b"])-style UDAs.
private final class LiteralStringCollector : ASTVisitor {
    alias visit = ASTVisitor.visit;
    string[] strings;

    override void visit(const PrimaryExpression node) {
        if (isStringLiteralToken(node.primary)) {
            strings ~= stripStringQuotes(node.primary.text);
            return;
        }
        node.accept(this);
    }
}

// Extracts string literals from a UDA argument expected to be a literal
// array of strings (e.g. @GazelleEmits(["a", "b"])) or a single literal
// string. Literal args only, per the plan: a non-literal argument (a
// variable, a call, string concatenation) is reported on stderr and
// contributes nothing rather than guessed at.
private string[] extractStringArrayArg(const ArgumentList argList, string udaName) {
    if (argList is null || argList.items.length == 0) {
        stderr.writefln("wedepend: @%s: no argument found; skipping", udaName);
        return [];
    }
    if (argList.items.length > 1) {
        stderr.writefln("wedepend: @%s: expected a single array-literal argument, got %d; skipping",
            udaName, argList.items.length);
        return [];
    }
    auto collector = new LiteralStringCollector;
    argList.items[0].accept(collector);
    if (collector.strings.length == 0) {
        stderr.writefln("wedepend: @%s: argument is not a literal string (array); skipping", udaName);
    }
    return collector.strings;
}

// Pending genemits/genpattern/genunknown/genctfecalls data collected from a
// Declaration's UDA list (visit(const Declaration node)) — attributes are
// visited before the declaration they annotate is reached (Declaration.accept
// visits `attributes` then `declarations`), so this is buffered here and
// flushed by emitDeclares once the declaration's name is known. Cleared
// unconditionally after each Declaration node (see visit(const Declaration)):
// a UDA that never reaches a top-level emitDeclares call (e.g. it decorates
// something outside file scope, or a declaration kind emitDeclares doesn't
// cover) is dropped rather than leaking into the next Declaration — a known
// P1 limitation (module-scope-only, see ScopeInfoVisitor doc comment).
private struct PendingUda {
    string[] emits;
    string[] patterns;
    bool unknown;
    string[] ctfeCalls;

    bool empty() const {
        return emits.length == 0 && patterns.length == 0 && !unknown && ctfeCalls.length == 0;
    }
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

    // Depth of enclosing CTFE-root contexts (see visitCtfe): enum member
    // initializers, static if/assert/foreach, template value arguments,
    // mixin(...) arguments, UDA arguments, pragma arguments, static array
    // dimensions, and module-level/static/immutable variable initializers.
    // Independent of bodyDepth — a CTFE root can appear INSIDE a function
    // body (e.g. a `static if` nested in a plain function) and still forces
    // compile-time evaluation of whatever it contains. Used to emit
    // `ctferef`/`ctferef_tmpl` for identifiers referenced in these positions
    // (docs/ctfe-per-symbol.md's CTFE-roots list) — a ref can be both an
    // ifaceref and a ctferef simultaneously (e.g. a manifest constant's
    // initializer at module scope is both).
    int ctfeDepth;

    // True while visiting a `public import`/`export import` declaration. Such
    // imports RE-EXPORT their symbols to consumers regardless of local use, so
    // they must always propagate — emitted as a `public <mod>` marker that the
    // scanner uses to exempt the module from usage-based reclassification.
    bool inPublicDecl;

    // See PendingUda's doc comment.
    PendingUda pendingUda;

    alias visit = ASTVisitor.visit;

    private bool isFileScope() const {
        return templateStack.length == 0 && containerStack.length == 0;
    }

    private string outerTemplate() const {
        return templateStack.length > 0 ? templateStack[0] : "";
    }

    // Nearest enclosing function's name (containerStack searched innermost
    // first, skipping non-func containers — a call nested in an `if` block
    // inside a function still attributes to that function). "_" for a call
    // with no enclosing function (module-scope initializer, aggregate field
    // default, etc.) — see the `call` tag's doc comment on FunctionCallExpression.
    private string currentFunctionName() const {
        foreach_reverse (c; containerStack) {
            if (c.kind == "func") return c.name;
        }
        return "_";
    }

    // Runs `node` with ctfeDepth incremented for its duration — used by every
    // CTFE-root context (see ctfeDepth's doc comment). Visits the WHOLE node
    // (not just its value sub-expression): for constructs with both a
    // compile-time-evaluated part and an ordinary body (static if/foreach),
    // this over-includes the body in ctfeDepth rather than precisely
    // isolating the condition/range expression — deliberate, matching the
    // plan's conservative bias (over-tagging a ctferef is safe; missing one
    // risks under-un-headering a file the CTFE walk actually needs raw).
    private void visitCtfe(const BaseNode node) {
        if (node is null) return;
        ctfeDepth++;
        scope(exit) ctfeDepth--;
        node.accept(this);
    }

    private static bool hasStorageClass(const StorageClass[] classes, string tokStr) {
        foreach (sc; classes) {
            if (sc is null) continue;
            if (str(sc.token.type) == tokStr) return true;
        }
        return false;
    }

    // Emits `declares <name> <kind>` for a MODULE-SCOPE (isFileScope) top-level
    // declaration only — P1 scope decision: aggregate members are not declared
    // individually here. Rationale (docs/ctfe-per-symbol.md's symbol->file
    // attribution design): a member resolves to a symbol via its ENCLOSING
    // aggregate anyway (the Go-side declares-index attributes a member access
    // like `Foo.bar` to Foo's file through Foo's own top-level declares entry),
    // so a separate per-member row isn't needed for file attribution — only
    // module-scope declarations need their own entry. Also flushes any
    // pendingUda collected from this declaration's attribute list (see
    // PendingUda) now that its name is known.
    private void emitDeclares(string name, string kind) {
        if (!isFileScope || name.length == 0) return;
        output.writefln("declares\t%s\t%s", name, kind);
        flushPendingUda(name);
    }

    // Flushes genemits/genpattern/genunknown/genctfecalls for `name` — the
    // BARE declaration name, matching how `instance` (TemplateInstance) and
    // `call` (FunctionCallExpression) already spell an instantiated/called
    // symbol, so the Go side can join on it regardless of nesting depth.
    //
    // Unlike `declares` (module-scope-only by design, see emitDeclares' doc
    // comment — symbol->file attribution goes through the ENCLOSING
    // aggregate's own top-level declares entry), the generator UDAs
    // (@GazelleEmits*/@GazelleCtfeCalls) annotate the GENERATOR itself, which
    // is routinely nested (a mixin template inside a class/struct, a CTFE
    // helper function inside a templated struct). Gating the flush on
    // isFileScope would silently drop those annotations. So this is called
    // unconditionally by every named-declaration visitor (both the
    // isFileScope branch via emitDeclares, and the nested/else branch) —
    // scope only decides whether `declares` also fires, not whether the
    // pending UDA data is kept.
    private void flushPendingUda(string name) {
        if (name.length == 0 || pendingUda.empty) return;
        foreach (n; pendingUda.emits) output.writefln("genemits\t%s\t%s", name, n);
        foreach (p; pendingUda.patterns) output.writefln("genpattern\t%s\t%s", name, p);
        if (pendingUda.unknown) output.writefln("genunknown\t%s", name);
        foreach (m; pendingUda.ctfeCalls) output.writefln("genctfecalls\t%s\t%s", name, m);
        pendingUda = PendingUda.init;
    }

    // Reads a single Attribute for our recognized generator UDAs
    // (@GazelleEmits / @GazelleEmitsPattern / @GazelleEmitsUnknown /
    // @GazelleCtfeCalls) and buffers matches into pendingUda — see its doc
    // comment for why this is buffered rather than emitted immediately.
    private void collectGazelleUda(const Attribute a) {
        if (a is null || a.atAttribute is null) return;
        auto at = a.atAttribute;
        string name = at.identifier.text;
        if (name.length == 0) return;
        switch (name) {
        case "GazelleEmits":
            pendingUda.emits ~= extractStringArrayArg(at.argumentList, name);
            break;
        case "GazelleEmitsPattern":
            pendingUda.patterns ~= extractStringArrayArg(at.argumentList, name);
            break;
        case "GazelleEmitsUnknown":
            pendingUda.unknown = true;
            break;
        case "GazelleCtfeCalls":
            pendingUda.ctfeCalls ~= extractStringArrayArg(at.argumentList, name);
            break;
        default:
            break;
        }
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
    //
    // Also scans this Declaration's attribute list for our recognized
    // generator UDAs (collectGazelleUda) before descending — Declaration.accept
    // visits attributes, then declarations, so the annotated declaration's
    // name isn't known yet; buffered in pendingUda and flushed by emitDeclares.
    // Any pendingUda that nothing consumed by the end of this Declaration is
    // dropped (see PendingUda's doc comment) rather than leaking sideways.
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

        foreach (a; node.attributes) {
            collectGazelleUda(a);
        }
        node.accept(this);
        pendingUda = PendingUda.init;
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
                    // Each entry is the LOCAL name (b.left — what's referenced at
                    // use sites in THIS file), optionally suffixed `=<original>`
                    // when the bind renames (`import mod : local = original;`,
                    // b.right). Un-renamed binds (the common case) keep the
                    // original bare-name format for back-compat with older Go-side
                    // parsers; a renamed bind is otherwise indistinguishable from
                    // an un-renamed one, which silently breaks any resolution that
                    // needs the symbol's ACTUAL name in `mod` (P3 declared-but-
                    // unreachable class (c), docs/ctfe-per-symbol.md).
                    string[] syms;
                    foreach (b; node.importBindings.importBinds) {
                        if (b is null) continue;
                        auto t = b.left.text;
                        if (t.length == 0) continue;
                        if (b.right.text.length > 0) syms ~= t ~ "=" ~ b.right.text;
                        else syms ~= t;
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
            emitDeclares(node.name.text, "tmpl");
        } else {
            // Nested mixin template (e.g. inside a class/struct) — `declares`
            // stays module-scope-only, but a @GazelleEmits*/@GazelleCtfeCalls
            // UDA on THIS declaration still needs to flush (see
            // flushPendingUda's doc comment).
            flushPendingUda(node.name.text);
        }
        templateStack ~= node.name.text;
        containerStack ~= Container("template", node.name.text);
        scope(exit) {
            templateStack = templateStack[0 .. $-1];
            containerStack = containerStack[0 .. $-1];
        }
        node.accept(this);
    }

    // kind: tmpl (has template params, incl. IFTI shorthand `foo(T)(T x)`) >
    // autoret (hasAuto — inferred return type, body survives hdrgen same as
    // a template) > plain (default/conservative: body elided by hdrgen).
    override void visit(const FunctionDeclaration node) {
        const isTemplate = node.templateParameters !is null;
        const topLevel = isFileScope;
        if (topLevel) {
            if (isTemplate) emitDeclares(node.name.text, "tmpl");
            else if (node.hasAuto) emitDeclares(node.name.text, "autoret");
            else emitDeclares(node.name.text, "plain");
        } else {
            // Nested function (e.g. a CTFE-string-generator method inside a
            // templated struct) — same rationale as TemplateDeclaration above.
            flushPendingUda(node.name.text);
        }
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
        if (topLevel) emitDeclares(node.name.text, isTemplate ? "tmpl" : "type");
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
        if (topLevel) emitDeclares(node.name.text, isTemplate ? "tmpl" : "type");
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
        if (topLevel) emitDeclares(node.name.text, isTemplate ? "tmpl" : "type");
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
        if (topLevel) emitDeclares(node.name.text, isTemplate ? "tmpl" : "type");
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

    // Named enums only — an anonymous `enum { A, B }` declares its MEMBERS
    // into the enclosing scope, not itself; out of scope for P1 (module-scope
    // top-level declarations only, see emitDeclares).
    override void visit(const EnumDeclaration node) {
        if (isFileScope && node.name.text.length > 0) {
            emitDeclares(node.name.text, "enum");
        }
        node.accept(this);
    }

    // enum init (CTFE root): each member's initializer expression is
    // evaluated at compile time.
    override void visit(const EnumMember node) {
        if (node.enumMemberAttributes !is null) {
            foreach (a; node.enumMemberAttributes) {
                if (a !is null) this.visit(a);
            }
        }
        if (node.type !is null) this.visit(node.type);
        visitCtfe(node.assignExpression);
    }

    // Old-style `alias Bar Foo;` (declaratorIdentifierList) and modern
    // `alias Foo = Bar;` (initializers) both declare their name(s) as `alias`.
    override void visit(const AliasDeclaration node) {
        if (isFileScope) {
            foreach (init; node.initializers) {
                if (init !is null && init.name.text.length > 0) {
                    emitDeclares(init.name.text, "alias");
                }
            }
            if (node.declaratorIdentifierList !is null) {
                foreach (t; node.declaratorIdentifierList.identifiers) {
                    if (t.text.length > 0) emitDeclares(t.text, "alias");
                }
            }
        }
        node.accept(this);
    }

    // Module-level (or explicitly static/immutable at any depth) variable
    // declaration(s) — `int x, y;`, `immutable int x = f();`. Each declarator
    // is its own top-level symbol. The initializer is a CTFE root when it's
    // module-scope or carries a static/immutable storage class (a local
    // `static immutable x = ctfeExpr();` inside an ordinary function is still
    // evaluated at compile time even though the function itself is runtime).
    override void visit(const VariableDeclaration node) {
        const topLevel = isFileScope;
        const ctfeInit = topLevel
            || hasStorageClass(node.storageClasses, "static")
            || hasStorageClass(node.storageClasses, "immutable");
        if (node.type !is null) this.visit(node.type);
        foreach (d; node.declarators) {
            if (d is null) continue;
            if (topLevel && d.name.text.length > 0) emitDeclares(d.name.text, "var");
            if (d.templateParameters !is null) this.visit(d.templateParameters);
            if (ctfeInit) visitCtfe(d.initializer);
            else if (d.initializer !is null) this.visit(d.initializer);
        }
        if (node.autoDeclaration !is null) this.visit(node.autoDeclaration);
    }

    // `auto x = ...;` and manifest-constant `enum x = ...;` share this AST
    // shape (distinguished only by an `enum` storage-class token). Same
    // module-scope/static/immutable CTFE-initializer rule as
    // VariableDeclaration, PLUS: an `enum` storage class always makes the
    // initializer a CTFE root regardless of depth (a manifest constant is
    // always compile-time, even one declared inside a function body).
    override void visit(const AutoDeclaration node) {
        const topLevel = isFileScope;
        const isEnum = hasStorageClass(node.storageClasses, "enum");
        const ctfeInit = topLevel || isEnum
            || hasStorageClass(node.storageClasses, "static")
            || hasStorageClass(node.storageClasses, "immutable");
        foreach (part; node.parts) {
            if (part is null) continue;
            if (topLevel && part.identifier.text.length > 0) {
                emitDeclares(part.identifier.text, isEnum ? "enum" : "var");
            }
            if (part.templateParameters !is null) this.visit(part.templateParameters);
            if (ctfeInit) visitCtfe(part.initializer);
            else if (part.initializer !is null) this.visit(part.initializer);
        }
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

    // static if condition (CTFE root) — the condition expression only; the
    // true/false branches are ordinary declarations/statements at their own
    // bodyDepth, reached normally via ConditionalDeclaration/ConditionalStatement
    // (not overridden here), so they are NOT included in ctfeDepth.
    override void visit(const StaticIfCondition node) {
        visitCtfe(node);
    }

    // static assert (CTFE root) — condition and message are both evaluated
    // at compile time.
    override void visit(const StaticAssertStatement node) {
        visitCtfe(node);
    }

    // static foreach, declaration position (module/aggregate scope) — e.g.
    // `static foreach (i; 0 .. N) { ... }` as a declaration. Foreach!true and
    // Foreach!false (ForeachStatement) are distinct D types from the same
    // template, so this doesn't collide with ordinary runtime foreach.
    // Whole construct (range expression AND generated body) is wrapped for
    // simplicity — see visitCtfe's doc comment on the conservative bias.
    override void visit(const StaticForeachDeclaration node) {
        visitCtfe(node);
    }

    // static foreach, statement position (inside a function body) — wraps an
    // ordinary ForeachStatement; same conservative whole-construct wrapping.
    override void visit(const StaticForeachStatement node) {
        visitCtfe(node);
    }

    // Template VALUE argument (as opposed to a type argument) in an
    // instantiation, e.g. the `3` in `Foo!(3)` — evaluated at compile time.
    override void visit(const TemplateArgument node) {
        if (node.type !is null) this.visit(node.type);
        visitCtfe(node.assignExpression);
    }

    // Same, for libdparse's named-template-argument node (`Foo!(T: int)` support):
    // newer libdparse builds instantiation args as NamedTemplateArgument, so the
    // TemplateArgument override above never fires there.
    override void visit(const NamedTemplateArgument node) {
        if (node.type !is null) this.visit(node.type);
        visitCtfe(node.assignExpression);
    }

    // mixin(...) argument expressions (CTFE root) — the string(s) being
    // mixed in must themselves be compile-time-computable.
    override void visit(const MixinExpression node) {
        visitCtfe(node);
    }

    // pragma(...) argument expressions (CTFE root).
    override void visit(const PragmaExpression node) {
        visitCtfe(node);
    }

    // Static array dimension expression(s) in a type, e.g. the `N` in `T[N]`
    // (CTFE root). `high` is also wrapped defensively (array-type-suffix
    // range forms); harmless if unused for a given suffix shape.
    override void visit(const TypeSuffix node) {
        if (node.type !is null) this.visit(node.type);
        visitCtfe(node.low);
        visitCtfe(node.high);
        if (node.parameters !is null) this.visit(node.parameters);
        foreach (a; node.memberFunctionAttributes) {
            if (a !is null) this.visit(a);
        }
    }

    // Emit every identifier referenced in an INTERFACE position (bodyDepth==0):
    // type names in signatures/fields, template params/constraints, manifest
    // initializers, default args — the identifiers that survive into the .di.
    // The Go/analysis side attributes each to its declaring module via the
    // top-level declares-index; a `top`/selective import propagates only if it
    // provides an ifaceref'd symbol. Body-only references (bodyDepth>0) are
    // omitted — they're elided from the .di and don't propagate.
    //
    // Separately (and not mutually exclusive — see ctfeDepth's doc comment),
    // emits `ctferef`/`ctferef_tmpl` when the reference is inside a CTFE-root
    // context: `ctferef_tmpl` when also inside a template (its enclosing body
    // survives hdrgen and is copied into every instantiator's compile, so the
    // ref propagates to consumers — the iface_top_required lesson), plain
    // `ctferef` otherwise.
    override void visit(const IdentifierOrTemplateInstance node) {
        string sym;
        if (node.identifier.text.length > 0) {
            sym = node.identifier.text;
        } else if (node.templateInstance !is null && node.templateInstance.identifier.text.length > 0) {
            sym = node.templateInstance.identifier.text;
        }
        if (sym.length > 0) {
            if (bodyDepth == 0) {
                output.writefln("ifaceref\t%s", sym);
            }
            if (ctfeDepth > 0) {
                output.writefln(templateStack.length > 0 ? "ctferef_tmpl\t%s" : "ctferef\t%s", sym);
            }
        }
        node.accept(this);
    }

    // UDAs (`@attribute(...)`, `@foo!T`) annotate declarations and are PRESERVED
    // in the .di (hdrgen keeps attributes on signatures), so their symbol leaks
    // through this file's interface and must count as an ifaceref. The UDA name
    // is a bare Token on AtAttribute (not wrapped in IdentifierOrTemplateInstance),
    // so the visitor above never sees it — emit it here. Same ctferef/ctferef_tmpl
    // extension as IdentifierOrTemplateInstance. UDA ARGUMENTS are themselves a
    // CTFE root (docs/ctfe-per-symbol.md) — ctfeDepth is incremented around
    // node.accept(this) (which visits templateInstance + argumentList), AFTER
    // the UDA's own name is checked against the depth in effect on entry (the
    // name itself isn't a "value" CTFE root, only its arguments are).
    override void visit(const AtAttribute node) {
        string sym;
        if (node.identifier.text.length > 0) {
            sym = node.identifier.text;
        } else if (node.templateInstance !is null && node.templateInstance.identifier.text.length > 0) {
            sym = node.templateInstance.identifier.text;
        }
        if (sym.length > 0) {
            if (bodyDepth == 0) {
                output.writefln("ifaceref\t%s", sym);
            }
            if (ctfeDepth > 0) {
                output.writefln(templateStack.length > 0 ? "ctferef_tmpl\t%s" : "ctferef\t%s", sym);
            }
        }
        visitCtfe(node);
    }

    override void visit(const TemplateInstance node) {
        if (node.identifier.text.length > 0) {
            output.writefln("instance\t%s\t%s", outerTemplate, node.identifier.text);
        }
        node.accept(this);
    }

    // call <containing-function> <callee> — containerStack's innermost
    // enclosing function (currentFunctionName; "_" for a call with no
    // enclosing function, e.g. a module-level manifest-constant initializer)
    // gives a per-function call graph instead of a file-level
    // over-approximation. NOTE: this repurposes the second field, which used
    // to carry the enclosing TEMPLATE name (empty when not in a template) —
    // gazelled's scan.go (build/gazelle/d/scan.go handleLine, "call" case)
    // never reads that field (only parts[2], the callee, populating a flat
    // callSet with no per-container attribution), so this is not a breaking
    // change to any current consumer; it's a free extension.
    override void visit(const FunctionCallExpression node) {
        // Skip explicit template calls foo!T(args) — the inner TemplateInstance already emits.
        if (node.templateArguments is null && node.unaryExpression !is null) {
            auto callee = extractCallee(node.unaryExpression);
            if (callee.length > 0) {
                output.writefln("call\t%s\t%s", currentFunctionName(), callee);
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
