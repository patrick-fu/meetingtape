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
          recover  Finalize a recording from preserved recovery materials

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
                              mono PCM CAF next to the main stereo file.
          -h, --help          Show this help.

        Channel layout of the main file:
          left   system audio, captured raw
          right  microphone audio with echo cancellation, noise suppression
                 and automatic gain control applied

        Speech-processing failures preserve raw microphone audio in the right
        channel. Use status --json to inspect degraded intervals and reasons.

        The command returns only after both audio sources are ready. The recording
        continues in a background host after this command exits. Only one session
        can run at a time. Set MEETINGTAPE_STATE_DIR to isolate session routing.

        Exit codes:
          0  recording started and ready
          1  invalid arguments or output directory
          4  capture failure or another session is starting or active
        """

    static let stop: String = """
        meetingtape stop - stop the active recording session

        Usage: meetingtape stop

        Exit codes:
          0  recording stopped and output files finalized
          3  no active recording session
          4  finalization or host communication failed; preserve recovery materials
        """

    static let status: String = """
        meetingtape status - print the current session state

        Usage: meetingtape status [--json]

        --json prints the core session snapshot, including interruption and
        degraded-interval metadata. With no active session it prints state "idle".

        Exit codes:
          0  status printed (this includes "no active session", which is a
             normal answer, not an error)
        """

    static let recover: String = """
        meetingtape recover - finalize preserved recording materials

        Usage: meetingtape recover <recovery-directory> --out <existing-directory>

        The destination must already exist and be writable. Recovery refuses an
        active writer and preserves materials if finalization fails.

        Exit codes:
          0  playable output files finalized
          1  invalid arguments
          4  recovery failed
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
