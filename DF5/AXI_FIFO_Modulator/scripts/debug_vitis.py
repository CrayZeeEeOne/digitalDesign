import os
import sys
import xsdb


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)

ELF_FILE = os.path.join(
    ROOT_DIR,
    "ws_vitis",
    "app_component",
    "build",
    "app_component.elf"
)


def main():
    print()
    print("==========================================")
    print("Starting MicroBlaze")
    print("==========================================")
    print()

    if not os.path.exists(ELF_FILE):
        print("ERROR: ELF does not exist:")
        print(ELF_FILE)
        sys.exit(1)

    print("Connecting to JTAG...")
    session = xsdb.start_debug_session()
    session.connect()

    print("Selecting MicroBlaze...")
    target = session.targets(3)

    print("Downloading ELF...")
    target.dow(ELF_FILE)

    print("Starting processor...")
    target.con()

    print("Continuing application...")
    target.con()

    print()
    print("==========================================")
    print("MicroBlaze application is running")
    print("==========================================")
    print()


if __name__ == "__main__":
    main()