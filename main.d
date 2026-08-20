module wedepend.main;

import std.algorithm;
import std.stdio;
import wedepend.depcalc;

int main(string[] rawArgs)
{
    bool includeUnittest;
    bool verbose;
    bool scopeInfoMode;
    string[] args;
    string[] versions;

    foreach(arg; rawArgs[1..$]) {
        switch(arg) {
        case "--unittest":
            includeUnittest = true;
            continue;
        case "-v":
        case "--verbose":
            verbose = true;
            break;
        case "--scope-info":
            scopeInfoMode = true;
            break;
        default:
            enum D_VERSION_STR = "-d-version=";
            enum D_VERSION_STR_LEN = D_VERSION_STR.length;
            if (arg.startsWith(D_VERSION_STR)) {
                string ver = arg[D_VERSION_STR_LEN .. $];
                versions ~= ver;

            } else {
                args ~= arg;
            }
            break;
        }
    }
    if (args.length != 1) {
        writeln(" Usage: ", rawArgs[0], " [--unittest|--scope-info] <input_file>");
        return 1;
    }

    if (scopeInfoMode) {
        stdout.scopeInfo(args[0]);
    } else {
        stdout.calcDependencies(args[0], includeUnittest, verbose, versions);
    }
    return 0;
}
