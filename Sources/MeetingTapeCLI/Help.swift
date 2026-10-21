import MeetingTapeCore

enum HelpText {
    static var overview: String {
        """
        meetingtape \(meetingTapeVersion) - record microphone and system audio into one stereo file

        Usage: meetingtape <command> [options]

        Commands:
          start    Begin a recording session (writes into --out directory)
          stop     Stop the active recording session
          status   Print the current session state
          doctor   Check environment readiness for recording

        Details:  meetingtape help <command>   (for example: meetingtape help start)
        Version:  meetingtape --version
        Exit codes: 0 ok / 1 usage error / 2 environment failure / 3 no active session / 4 capture failure
        """
    }

    static let start: String = """
        meetingtape start - begin a recording session

        Usage: meetingtape start --out <directory> [--keep-raw]

        Options:
          --out <directory>   Required, no default. Directory that receives the
                              recording file(s). It must already exist and be
                              writable; the CLI never creates it for you.
          --keep-raw          Also keep the raw microphone track as a separate
                              file next to the main stereo file.
          -h, --help          Show this help.

        Channel layout of the main file:
          left   system audio, captured raw
          right  microphone audio with echo cancellation, noise suppression
                 and automatic gain control applied

        Notes:
          This scaffold build validates the arguments and then reports that
          audio capture is not implemented yet (exit 4).

        Exit codes:
          0  recording started (once capture lands)
          1  usage error: missing --out, unknown option, or --out is not an
             existing writable directory
          4  capture failure (current builds: capture not available)
        """

    static let stop: String = """
        meetingtape stop - stop the active recording session

        Usage: meetingtape stop

        Exit codes:
          0  recording stopped
          3  no active recording session
        """

    static let status: String = """
        meetingtape status - print the current session state

        Usage: meetingtape status

        Output is a single line, for example:
          status: no active recording session

        Exit codes:
          0  status printed (this includes "no active session", which is a
             normal answer, not an error)
        """

    static let doctor: String = """
        meetingtape doctor - check environment readiness for recording

        Usage: meetingtape doctor [--out <directory>]

        Checks:
          macOS version   14.2 or newer (CoreAudio tap API)
          audio devices   at least one input and one output device
          --out           optional: directory exists and is writable

        Permission prompts (microphone, audio capture) appear on the first
        real capture and are therefore not part of this check.

        Exit codes:
          0  all checks passed
          2  at least one check failed
          1  usage error
        """
}
