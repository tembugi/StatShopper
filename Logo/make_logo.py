# Renders the logo, FindMyStats-logo.svg (the drawing, 1024 px), to:
# - FindMyStats-logo.png, 400 x 400, for CurseForge
# - ../Icon.tga, 128 x 128, the addon's icon in the game's addon list (## IconTexture)
# Run in this folder: python3 make_logo.py. Needs macOS (its Georgia and Palatino fonts) and
# Google Chrome, which draws the SVG.
import os
import subprocess
import tempfile
import time

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
NAME = "FindMyStats"

with tempfile.TemporaryDirectory() as tmp:
    shot = os.path.join(tmp, "logo-1024.png")
    chrome = subprocess.Popen([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                               f"--user-data-dir={tmp}/profile", "--window-size=1024,1024",
                               f"--screenshot={shot}", "file://" + os.path.join(HERE, NAME + "-logo.svg")],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # Headless Chrome saves the picture but sometimes doesn't exit: stop it once the file is in.
    for _ in range(300):
        if chrome.poll() is not None or (os.path.exists(shot) and os.path.getsize(shot) > 0):
            break
        time.sleep(0.1)
    time.sleep(0.5)
    chrome.kill()
    chrome.wait()
    logo = Image.open(shot).convert("RGB")
    logo.resize((400, 400), Image.LANCZOS).save(os.path.join(HERE, NAME + "-logo.png"))
    # The game reads TGA: 32-bit, uncompressed, power-of-two size.
    logo.resize((128, 128), Image.LANCZOS).convert("RGBA").save(os.path.join(HERE, "..", "Icon.tga"))
print("saved", NAME + "-logo.png", "and Icon.tga")
