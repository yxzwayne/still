# Still development workflow

After each completed change that affects the app, run the relevant checks and then `Scripts/build.sh --install` from the project root. This is Wayne’s standing request to update `/Applications/Still.app`. Use the same release build for verification and installation. If the install succeeds, report it. If the environment blocks installation, report that the build is ready and give the exact install command.

An install updates the app on disk. Let a running conversation finish and take up the update on the next launch unless Wayne asks for an immediate restart.
