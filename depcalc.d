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

    override void visit(const FunctionBody functionBody)
    {
        //functionBody.accept(this);
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
        //stderr.writefln(" version condition len %d at %d: %s (%s)", condDecls.length, visitor.token.line, visitor.token.text, str(visitor.token.type));
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
