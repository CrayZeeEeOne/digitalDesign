import os
import sys
import vitis


# ============================================================
# PATHS
# ============================================================

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)

XSA_FILE = os.path.join(ROOT_DIR, "project", "DF5_project.xsa")
WORKSPACE = os.path.join(ROOT_DIR, "ws_vitis")
MAIN_C = os.path.join(ROOT_DIR, "vitis", "app_component", "src", "main.c")


print("==========================================")
print("Vitis build")
print("==========================================")
print()

print("XSA:")
print("  " + XSA_FILE)

print()
print("Workspace:")
print("  " + WORKSPACE)

print()
print("Source:")
print("  " + MAIN_C)

print()


# ============================================================
# CHECK
# ============================================================

if not os.path.isfile(XSA_FILE):
    print("ERROR: XSA does not exist:")
    print("  " + XSA_FILE)
    sys.exit(1)

if not os.path.isfile(MAIN_C):
    print("ERROR: main.c does not exist:")
    print("  " + MAIN_C)
    sys.exit(1)


# ============================================================
# VITIS CLIENT
# ============================================================

print("==========================================")
print("Creating Vitis client")
print("==========================================")

client = vitis.create_client()

client.set_workspace(path=WORKSPACE)


# ============================================================
# PLATFORM
# ============================================================

print()
print("==========================================")
print("Creating platform")
print("==========================================")

platform = client.create_platform_component(
    name="DF5_platform",
    hw_design=XSA_FILE,
    cpu="microblaze_0",
    os="standalone"
)

print()
print("==========================================")
print("Building platform")
print("==========================================")

platform.build()


# ============================================================
# APPLICATION
# ============================================================

print()
print("==========================================")
print("Creating application")
print("==========================================")

platform_xpfm = client.find_platform_in_repos("DF5_platform")

app = client.create_app_component(
    name="app_component",
    platform=platform_xpfm
)


# ============================================================
# SOURCE
# ============================================================

print()
print("==========================================")
print("Importing main.c")
print("==========================================")

app.import_files(
    from_loc=os.path.dirname(MAIN_C),
    files=["main.c"],
    dest_dir_in_cmp="src"
)


# ============================================================
# BUILD
# ============================================================

print()
print("==========================================")
print("Building application")
print("==========================================")

app.build()


# ============================================================
# DONE
# ============================================================

print()
print("==========================================")
print("VITIS BUILD DONE")
print("==========================================")
print()
