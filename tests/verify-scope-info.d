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
