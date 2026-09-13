import Darwin
import JMacToolCore

if ProxyCLI.shouldRunAsCLI(CommandLine.arguments) {
    exit(ProxyCLI.run())
}

AppLauncher.run()
