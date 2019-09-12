module wedepend.main;

import std.stdio;
import wedepend.depcalc;

int main(string[] rawArgs)
{
    bool includeUnittest;
    bool verbose;
    string[] args;

    foreach(arg; rawArgs[1..$]) {
        switch(arg) {
        case "--unittest":
            includeUnittest = true;
            continue;
        case "-v":
        case "--verbose":
            verbose = true;
            break;
        default:
            args ~= arg;
            break;
        }
    }
    if (args.length != 1) {
        writeln(" Usage: ", args[0], " [--unittest] <input_file>");
        return 1;
    }

    stdout.calcDependencies(args[0], includeUnittest, verbose);
    return 0;
}
