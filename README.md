# ISO/IMG Writer for SD Card/USB

This script writes ISO or IMG files to SD cards or USB drives on Linux and macOS.

## Prerequisites

* **Bash** (standard on Linux/macOS).
* **`pv` (Pipe Viewer):** Optional, but **highly recommended** for progress display.
    * _Linux:_ `sudo apt install pv` or `sudo dnf install pv`
    * _macOS:_ `brew install pv`

## Quick Start

1.  **Prepare Image:** Place your image file in the same directory as the script and name it `img.img`.
    * _If `img.img` is not found, the script will ask for the file path._

2.  **Run Script:** Open your terminal in the script's directory and execute:
    ```bash
    bash write.sh
    ```

3.  **Follow Prompts:**
    * The script will list available disks. **Carefully identify your target disk.**
    * Enter the disk name (e.g., `/dev/sdb`, `/dev/disk2`).
        * _On macOS, if you enter `/dev/diskX`, it may offer to use the faster `/dev/rdiskX`._
    * **Confirm the operation by typing `EVET` or `YES` when prompted.**

## !! CRITICAL WARNINGS !!

* **DATA WILL BE ERASED:** The selected disk will be **COMPLETELY WIPED**. There is NO UNDO.
* **CHOOSE THE CORRECT DISK:** Writing to the wrong disk (like your system drive) will cause **irreversible data loss**. Double-check the disk name and size.

---
Use with extreme caution.
