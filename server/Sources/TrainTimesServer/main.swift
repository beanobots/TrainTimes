import Foundation
import TrainCore

exit(await ServerMain.run(arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment))
