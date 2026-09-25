import os
import sys
import shutil
import vitis


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)

XSA_FILE = os.path.join(
    ROOT_DIR,
    "project",
    "DF5_project.xsa"
)

WORKSPACE = os.path.join(
    ROOT_DIR,
    "ws_vitis"
)

MAIN_C = os.path.join(
    ROOT_DIR,
    "vitis",
    "app_component",
    "src",
    "main.c"
)


# --------------------------------------------------
# Check files
# --------------------------------------------------

if not os.path.exists(XSA_FILE):
    print("ERROR: XSA does not exist:")
    print(XSA_FILE)
    sys.exit(1)

if not os.path.exists(MAIN_C):
    print("ERROR: main.c does not exist:")
    print(MAIN_C)
    sys.exit(1)


# --------------------------------------------------
# Create Vitis client
# --------------------------------------------------

print()
print("==========================================")
print("Starting Vitis")
print("==========================================")
print()

client = vitis.create_client()
client.set_workspace(path=WORKSPACE)


# --------------------------------------------------
# Create platform
# --------------------------------------------------

print()
print("==========================================")
print("Creating platform")
print("==========================================")
print()

platform = client.create_platform_component(
    name="DF5_platform",
    hw_design=XSA_FILE,
    cpu="microblaze_0",
    os="standalone"
)

platform.build()


# --------------------------------------------------
# Find platform
# --------------------------------------------------

platform_xpfm = client.find_platform_in_repos("DF5_platform")


# --------------------------------------------------
# Create application
# --------------------------------------------------

print()
print("==========================================")
print("Creating application")
print("==========================================")
print()

app = client.create_app_component(
    name="app_component",
    platform=platform_xpfm
)


# --------------------------------------------------
# Import source
# --------------------------------------------------

app.import_files(
    from_loc=os.path.dirname(MAIN_C),
    files=["main.c"],
    dest_dir_in_cmp="src"
)


# --------------------------------------------------
# Build application
# --------------------------------------------------

print()
print("==========================================")
print("Building application")
print("==========================================")
print()

app.build()


print()
print("==========================================")
print("VITIS BUILD DONE")
print("==========================================")
print()