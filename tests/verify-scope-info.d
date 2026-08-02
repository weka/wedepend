module verify;

import a.b;
import std.algorithm : map, filter;
import c.d, e.f;

void plain() {
    import scoped_a;
    if (true) {
        import scoped_b : x;
    }
}

template T(X) {
    import in_template;
    import named : x, y;
    void inner() {
        foo!(int)(42);
        bar(1);
    }
}

void topCall() { baz(1); }

void templatedFunc(T)(T x) {
    import in_func_tmpl;
    qux(x);
}

struct S(T) {
    import in_struct_tmpl;
    void method() { stuff(); }
}

class Plain {
    import in_class;
    void method() {
        widget!T(1);
    }
}

// --- declares: kind classification ---

void plainFunc() {}                    // declares plainFunc plain
auto autoFunc() { return 1; }          // declares autoFunc autoret
void tmplFunc(T)(T x) {}                // declares tmplFunc tmpl (already covered by templatedFunc above too)
struct PlainStruct {}                   // declares PlainStruct type
struct TmplStruct(T) {}                 // declares TmplStruct tmpl
class PlainClass {}                     // declares PlainClass type
interface PlainIface {}                 // declares PlainIface type
union PlainUnion {}                     // declares PlainUnion type
enum Color { Red, Green, Blue }         // declares Color enum
enum manifestConst = 42;                // declares manifestConst enum (AutoDeclaration + enum storage class)
auto autoVar = 7;                       // declares autoVar var (AutoDeclaration, no enum storage class)
int plainVar;                           // declares plainVar var
alias AliasNew = PlainStruct;           // declares AliasNew alias
alias PlainStruct OldStyleAlias;        // declares OldStyleAlias alias (old-style declaratorIdentifierList)

// Eponymous template: only the outer TemplateDeclaration is file-scope, so
// only ONE declares line (Epon tmpl) — the inner eponymous function is
// nested, not module-scope.
template Epon(T) {
    void Epon(T x) {}
}

// --- ctferef: CTFE-root contexts ---

enum EnumWithRef { A = CtfeRefA, B }             // ctferef CtfeRefA (enum init)

static if (SomeCtfeCond) {                       // ctferef SomeCtfeCond (static if)
    void staticIfBranch() {}
}

static assert(SomeAssertCond, "message");        // ctferef SomeAssertCond (static assert)

void withLocalStaticIf() {
    static if (LocalCtfeCond) {                  // ctferef LocalCtfeCond, even though enclosing fn is plain
    }
}

template TemplValueArg(alias X = TemplDefaultRef) {}  // best-effort; primarily testing TemplateArgument below

void useTemplateValueArg() {
    InstantiateWithValue!(TemplArgRefValue) dummy;   // ctferef TemplArgRefValue (template value arg)
}

void useMixin() {
    mixin(MixinArgRef);                          // ctferef MixinArgRef (mixin arg)
}

@UdaWithArgRef(UdaArgRefValue)                   // ctferef UdaArgRefValue (UDA arg) + ifaceref UdaWithArgRef
void udaAnnotated() {}

void usePragma() {
    pragma(msg, PragmaArgRef);                    // ctferef PragmaArgRef (pragma arg)
}

int[StaticArrayDimRef] staticArrayVar;            // ctferef StaticArrayDimRef (static array dim)

immutable immutableModuleVar = ImmutableInitRef;  // ctferef ImmutableInitRef (module-level initializer)

void localStaticImmutable() {
    static immutable localStaticVar = LocalStaticInitRef;  // ctferef LocalStaticInitRef, even inside plain fn
}

template CtfeRefTmplBody(T) {
    void bodyFn() {
        static if (InTemplateBodyCtfeRef) {}      // ctferef_tmpl InTemplateBodyCtfeRef (template-body ctferef)
    }
}

// --- call: containing-function context ---

void callerFunc() {
    calleeFromCallerFunc();                       // call callerFunc calleeFromCallerFunc
}

void moduleScopeCallTarget() {}
CallResultHolder moduleLevelCall = capturesModuleCall();  // call _ capturesModuleCall (module scope, no enclosing func)

// --- UDA recognition: genemits/genpattern/genunknown/genctfecalls ---

@GazelleEmits(["emittedOne", "emittedTwo"])
void generatorEmitsFixed() {}

@GazelleEmitsPattern(["<0>_ID_OPS"])
void generatorEmitsPattern(T)(T x) {}

@GazelleEmitsUnknown
void generatorEmitsUnknown() {}

@GazelleCtfeCalls(["example.some.module"])
void generatorCtfeCalls() {}

@GazelleEmits(someRuntimeArray)                   // non-literal — should warn on stderr, emit nothing
void generatorNonLiteralArg() {}
