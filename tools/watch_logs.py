#!/usr/bin/env python3
"""
Log watcher for erlcracker
Tails the log file with colorized output for better readability
"""

import sys
import time
import os
from pathlib import Path

try:
    from colorama import Fore, Style, init
    init(autoreset=False)  # Don't auto-reset after each print

    # Use colorama colors
    class Colors:
        RESET = Style.RESET_ALL
        BOLD = Style.BRIGHT

        # Log levels
        DEBUG = Fore.CYAN
        INFO = Fore.GREEN
        WARNING = Fore.YELLOW
        ERROR = Fore.RED

        # Components
        TIME = Fore.BLACK + Style.BRIGHT  # Bright black = gray
        MODULE = Fore.MAGENTA
        PID = Fore.BLUE

except ImportError:
    # Fallback to ANSI codes if colorama not installed
    class Colors:
        RESET = '\033[0m'
        BOLD = '\033[1m'

        # Log levels
        DEBUG = '\033[36m'      # Cyan
        INFO = '\033[32m'       # Green
        WARNING = '\033[33m'    # Yellow
        ERROR = '\033[31m'      # Red

        # Components
        TIME = '\033[90m'       # Gray
        MODULE = '\033[35m'     # Magenta
        PID = '\033[34m'        # Blue


def colorize_line(line):
    """Add colors to log line based on content"""
    # Skip empty lines
    if not line.strip():
        return line

    # Colorize timestamp
    if line.startswith('20'):  # Timestamp starts with year
        parts = line.split(' ', 2)
        if len(parts) >= 3:
            timestamp = f"{Colors.TIME}{parts[0]} {parts[1]}{Colors.RESET}"
            rest = parts[2]

            # Colorize log level
            if '[debug]' in rest.lower():
                rest = rest.replace('[debug]', f'{Colors.DEBUG}[debug]{Colors.RESET}')
                rest = rest.replace('[DEBUG]', f'{Colors.DEBUG}[DEBUG]{Colors.RESET}')
            elif '[info]' in rest.lower():
                rest = rest.replace('[info]', f'{Colors.INFO}[info]{Colors.RESET}')
                rest = rest.replace('[INFO]', f'{Colors.INFO}[INFO]{Colors.RESET}')
            elif '[warning]' in rest.lower():
                rest = rest.replace('[warning]', f'{Colors.WARNING}[warning]{Colors.RESET}')
                rest = rest.replace('[WARNING]', f'{Colors.WARNING}[WARNING]{Colors.RESET}')
            elif '[error]' in rest.lower():
                rest = rest.replace('[error]', f'{Colors.ERROR}{Colors.BOLD}[error]{Colors.RESET}')
                rest = rest.replace('[ERROR]', f'{Colors.ERROR}{Colors.BOLD}[ERROR]{Colors.RESET}')

            # Highlight PIDs
            import re
            rest = re.sub(r'<\d+\.\d+\.\d+>', lambda m: f'{Colors.PID}{m.group()}{Colors.RESET}', rest)

            # Highlight erlcracker components
            for keyword in ['erlcracker_pool', 'erlcracker_worker', 'erlcracker_python_runtime',
                          'worker_available', 'worker_done', 'call_runtime', 'start_runtime']:
                if keyword in rest:
                    rest = rest.replace(keyword, f'{Colors.MODULE}{keyword}{Colors.RESET}')

            return f"{timestamp} {rest}"

    return line


def tail_file(filepath, follow=True):
    """Tail a file and yield lines, optionally following new content"""
    filepath = Path(filepath)

    # Wait for file to exist
    while not filepath.exists():
        print(f"Waiting for log file: {filepath}")
        time.sleep(1)

    with open(filepath, 'r') as f:
        # Go to end of file
        f.seek(0, os.SEEK_END)

        print(f"{Colors.BOLD}Watching logs: {filepath}{Colors.RESET}")
        print(f"{Colors.BOLD}Press Ctrl+C to stop{Colors.RESET}\n")

        while True:
            line = f.readline()
            if line:
                yield line
            elif follow:
                time.sleep(0.1)  # Wait a bit before trying again
            else:
                break


def main():
    # Get log file path
    script_dir = Path(__file__).parent
    log_file = script_dir.parent / 'log' / 'erlcracker.log'

    # Parse command line args
    show_all = '--all' in sys.argv or '-a' in sys.argv
    no_follow = '--no-follow' in sys.argv or '-n' in sys.argv

    try:
        if show_all and log_file.exists():
            # Show entire file first
            print(f"{Colors.BOLD}=== Existing logs ==={Colors.RESET}\n")
            with open(log_file, 'r') as f:
                for line in f:
                    print(colorize_line(line), end='')
            print(f"\n{Colors.BOLD}=== Following new logs ==={Colors.RESET}\n")

        # Tail the file
        for line in tail_file(log_file, follow=not no_follow):
            print(colorize_line(line), end='')
            sys.stdout.flush()

    except KeyboardInterrupt:
        print(f"\n\n{Colors.BOLD}Log watcher stopped{Colors.RESET}")
        sys.exit(0)
    except Exception as e:
        print(f"\n{Colors.ERROR}Error: {e}{Colors.RESET}", file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
