# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for a security problem.

Report it privately through GitHub:
[Security → Report a vulnerability](https://github.com/BikaSolution/nengine/security/advisories/new).

Include what you found, how to reproduce it (a crafted asset, save or script
file is ideal), and what it lets an attacker do.

## Scope

nengine reads text files it did not write: `.sprite`, `.char`, `.scene`,
`.song`, `.sound`, `.inst`, `.cut`, `.talk` and save files. A file that crashes
the engine, hangs it, exhausts memory, or reads or writes outside the folders
it was given is in scope.

## Supported versions

Only the latest commit on `main` is supported.
