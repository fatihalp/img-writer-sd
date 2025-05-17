#!/bin/bash

LINUX_USE_OFLAG_DIRECT=true
# Dinamik blok boyutu hesaplamasını geçersiz kılmak için buraya bir değer girin (örn: "64M", "128M").
# Dinamik hesaplama/varsayılan için boş bırakın veya "AUTO" olarak ayarlayın.
# Önceki isteğiniz üzerine 128M ile sorun yaşandığı için "AUTO" bırakıp scriptin daha küçük bir değer bulmasını sağlayabilirsiniz.
# Veya spesifik olarak "32M", "64M" gibi bir değer deneyebilirsiniz.
USER_DD_BLOCK_SIZE_OVERRIDE="AUTO"
PV_UPDATE_INTERVAL=5

# --- Script Internal Variables ---
FINAL_DD_BLOCK_SIZE="" # dd için kullanılacak nihai blok boyutu

function determine_block_size() {
    local disk_device_name="$1" # e.g., /dev/sdb
    local determined_bs=""
    local base_disk_name=$(basename "$disk_device_name")

    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        # /sys/block/sdX/queue/optimal_io_size (bayt cinsinden) okumayı dene
        local optimal_io_s
        if optimal_io_s=$(cat "/sys/block/$base_disk_name/queue/optimal_io_size" 2>/dev/null) && [[ "$optimal_io_s" -gt 0 ]]; then
            # Değeri dd için makul bir 'M' değerine dönüştür
            if [[ "$optimal_io_s" -ge 67108864 ]]; then # >= 64MB
                determined_bs="64M"
            elif [[ "$optimal_io_s" -ge 33554432 ]]; then # >= 32MB
                determined_bs="32M"
            elif [[ "$optimal_io_s" -ge 16777216 ]]; then # >= 16MB
                determined_bs="16M"
            elif [[ "$optimal_io_s" -ge 4194304 ]]; then  # >= 4MB
                determined_bs="4M"
            elif [[ "$optimal_io_s" -ge 1048576 ]]; then  # >= 1MB
                determined_bs="1M"
            else # optimal_io_s < 1MB ise, (örneğin 512KB ise 8x = 4MB olacak şekilde)
                 # Daha karmaşık bir mantık yerine, küçük optimal_io için güvenli bir varsayılan kullan.
                if [[ "$optimal_io_s" -ge 524288 ]]; then # 512KB ise
                    determined_bs="4M"
                else # Daha da küçükse veya belirlenemiyorsa
                    determined_bs="4M" # Güvenli bir alt sınır
                fi
            fi
            if [[ -n "$determined_bs" ]]; then
                 echo "Info: Suggested block size based on optimal_io_size ($optimal_io_s bytes): $determined_bs"
            fi
        fi

        # optimal_io_size bulunamadıysa veya çok küçükse, physical_block_size'a bak
        if [[ -z "$determined_bs" ]]; then
            local physical_bs
            if physical_bs=$(cat "/sys/block/$base_disk_name/queue/physical_block_size" 2>/dev/null) && [[ "$physical_bs" -ge 512 ]]; then
                if [[ "$physical_bs" -ge 4096 ]]; then # 4K veya üzeri sektörler için
                    determined_bs="4M" # 4M genellikle iyi bir başlangıçtır
                else # 512 byte sektörler için
                    determined_bs="1M" # Daha küçük bir varsayılan
                fi
                echo "Info: Suggested block size based on physical_block_size ($physical_bs bytes): $determined_bs"
            fi
        fi
    fi

    if [[ -n "$USER_DD_BLOCK_SIZE_OVERRIDE" && "$USER_DD_BLOCK_SIZE_OVERRIDE" != "AUTO" ]]; then
        FINAL_DD_BLOCK_SIZE="$USER_DD_BLOCK_SIZE_OVERRIDE"
        echo "Info: Using user-defined block size: $FINAL_DD_BLOCK_SIZE"
    elif [[ -n "$determined_bs" ]]; then
        FINAL_DD_BLOCK_SIZE="$determined_bs"
        echo "Info: Using dynamically suggested block size for '$disk_device_name': $FINAL_DD_BLOCK_SIZE"
    else
        # Nihai varsayılan (eğer sysfs bilgisi yoksa/işe yaramazsa ve kullanıcı override etmediyse)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            FINAL_DD_BLOCK_SIZE="4M" # macOS için genellikle rdisk kullanımı bs'den daha etkilidir
        else
            # Önceki 128M sorunları göz önüne alındığında daha güvenli bir varsayılan
            FINAL_DD_BLOCK_SIZE="16M"
        fi
        echo "Info: Using default block size for '$disk_device_name': $FINAL_DD_BLOCK_SIZE"
    fi
}


function find_disk() {
    echo "--------------------------------------------------------------------"
    echo "Listing available block devices..."
    echo "--------------------------------------------------------------------"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macOS Disks (from diskutil list):"
        diskutil list
        echo ""
        echo "Identify your target disk from the list above (e.g., /dev/disk6)."
        echo "Use the IDENTIFIER for the *whole* disk, not a partition (e.g., disk6s1)."
    elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Linux Disks (from lsblk -d -o NAME,SIZE,MODEL,VENDOR,TRAN,TYPE,PATH):"
        lsblk -d -o NAME,SIZE,MODEL,VENDOR,TRAN,TYPE,PATH
        echo ""
        echo "Identify your target disk from the list above (e.g., /dev/sdb, /dev/nvme0n1)."
        echo "Select the whole disk device, not a partition."
    else
        echo "Unsupported OS: $OSTYPE. Please identify your disk manually."
    fi
    echo "--------------------------------------------------------------------"
}

find_disk

read -p "Enter target disk name (e.g., /dev/disk6 or /dev/sdb): " disk_name
img_path_default="img.img"
img_path="$img_path_default"

if [[ "$OSTYPE" == "darwin"* ]] && [[ "$disk_name" =~ ^/dev/disk([0-9]+)$ ]]; then
    rdisk_name="/dev/rdisk${BASH_REMATCH[1]}"
    read -p "On macOS, using '$rdisk_name' (raw disk) is often faster. Use '$rdisk_name' instead of '$disk_name'? (yes/NO): " use_rdisk
    if [[ "$use_rdisk" == "yes" ]]; then
        disk_name="$rdisk_name"
        echo "Using raw disk: $disk_name"
    fi
fi

# Blok boyutunu belirle (kullanıcı override'ı veya dinamik/varsayılan)
determine_block_size "$disk_name"

if [[ ! -f "$img_path" ]]; then
    echo "Default image '$img_path_default' not found."
    read -p "Enter full path to your image file: " custom_img_path
    if [[ ! -f "$custom_img_path" ]]; then
        echo "Error: Image file '$custom_img_path' not found. Exiting."
        exit 1
    fi
    img_path="$custom_img_path"
fi

echo "Using image file: $img_path"
echo "Effective dd block size: $FINAL_DD_BLOCK_SIZE" # Değişti: FINAL_DD_BLOCK_SIZE
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Linux oflag=direct setting: $LINUX_USE_OFLAG_DIRECT"
fi

if ! command -v pv &> /dev/null; then
    echo ""
    echo "--------------------------------------------------------------------"
    echo "Warning: 'pv' (Pipe Viewer) not installed. Progress details (ETA, percentage) unavailable."
    echo "Basic 'dd' status might show on some Linux systems."
    echo "Install 'pv': macOS (Homebrew): 'brew install pv' | Debian/Ubuntu: 'sudo apt install pv' | Fedora: 'sudo dnf install pv'"
    echo "--------------------------------------------------------------------"
    read -p "Continue without detailed progress? (yes/no): " continue_without_pv
    if [[ "$continue_without_pv" != "yes" ]]; then
        echo "Exiting. Please install 'pv' or agree to continue without it."
        exit 1
    fi
    PV_INSTALLED=false
else
    PV_INSTALLED=true
    if [[ "$OSTYPE" == "darwin"* ]]; then
        img_size=$(stat -f%z "$img_path")
    else
        img_size=$(stat -c%s "$img_path")
    fi
    if ! [[ "$img_size" =~ ^[0-9]+$ ]] || [[ "$img_size" -eq 0 ]]; then
        echo "Error: Could not determine size of '$img_path' or file is empty. Exiting."
        exit 1
    fi
fi

if [[ -z "$disk_name" ]]; then
    echo "Error: Disk name cannot be empty. Exiting."
    exit 1
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    if ! [[ "$disk_name" =~ ^/dev/(r?disk)[0-9]+$ ]]; then
        echo "Warning: On macOS, disk name should be like /dev/diskX or /dev/rdiskX."
        echo "You entered: '$disk_name'. Ensure this is the correct *whole disk identifier*."
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if ! [[ "$disk_name" =~ ^/dev/(sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|xvd[a-z]+|vd[a-z]+)$ ]]; then
        echo "Warning: On Linux, disk name is typically /dev/sdx, /dev/nvmeXnY, /dev/mmcblkX, etc."
        echo "You entered: '$disk_name'. Ensure this is the correct *whole disk identifier*."
    fi
fi

read -p "SURE you want to write '$img_path' to '$disk_name'? THIS WILL ERASE ALL DATA ON '$disk_name'. Type 'YES' to confirm: " confirmation
if [[ "$confirmation" != "YES" ]]; then
    echo "Operation cancelled."
    exit 0
fi

echo "Checking if $disk_name or its partitions are in use/mounted..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "Attempting to unmount all volumes on $disk_name (macOS)..."
    if ! diskutil unmountDisk "$disk_name"; then
        echo "Error: Failed to unmount $disk_name on macOS. It might be in use or identifier is incorrect."
        exit 1
    else
        echo "Successfully unmounted volumes on $disk_name (macOS)."
    fi
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "Attempting to unmount partitions on $disk_name and disable swap (Linux)..."
    PARTS_TO_UNMOUNT=$(lsblk -lnro NAME,TYPE,MOUNTPOINT "$disk_name" | awk '$2~/part|lvm|md/ && ($3!="" || $3=="[SWAP]") {print $1}')
    if [[ -n "$PARTS_TO_UNMOUNT" ]]; then
        for part_name in $PARTS_TO_UNMOUNT; do
            local_part_path="/dev/$part_name"
            current_mountpoint=$(lsblk -lnro MOUNTPOINT "$local_part_path")
            if [[ "$current_mountpoint" == "[SWAP]" ]]; then
                echo "Disabling swap on $local_part_path..."
                if ! sudo swapoff "$local_part_path"; then
                    echo "Error: Could not disable swap on $local_part_path."
                    exit 1
                fi
            elif [[ -n "$current_mountpoint" ]] && [[ "$current_mountpoint" != " " ]]; then
                echo "Unmounting $local_part_path from $current_mountpoint..."
                if ! sudo umount "$local_part_path"; then
                    echo "Error: Could not unmount $local_part_path."
                    exit 1
                fi
            fi
        done
        echo "Successfully unmounted partitions/disabled swap on $disk_name."
    else
        echo "No actively mounted partitions or swap found on $disk_name."
    fi
    if command -v lsof &> /dev/null && lsof "$disk_name" &> /dev/null; then
        echo "Warning: 'lsof' indicates '$disk_name' might still be in use:"
        lsof "$disk_name"
        read -p "Continue despite 'lsof' warning? (yes/NO): " lsof_continue
        if [[ "$lsof_continue" != "yes" ]]; then
            echo "Operation cancelled due to lsof warning."
            exit 1
        fi
    fi
fi

echo ""
echo "Writing '$img_path' to '$disk_name'..."
echo "This may take a while. Effective block size: $FINAL_DD_BLOCK_SIZE" # Değişti
echo ""

DD_CMD_BASE="dd of='$disk_name' bs='$FINAL_DD_BLOCK_SIZE'" # Değişti
DD_OFLAGS=""
DD_STATUS_PROGRESS=""

if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    if [[ "$LINUX_USE_OFLAG_DIRECT" == true ]]; then
        DD_OFLAGS="oflag=direct"
    fi
    DD_STATUS_PROGRESS="status=progress"
    DD_CMD="$DD_CMD_BASE $DD_OFLAGS"
else
    DD_CMD="$DD_CMD_BASE"
fi

if [[ "$PV_INSTALLED" == true ]]; then
    echo "Using 'pv' for progress (Update interval: ${PV_UPDATE_INTERVAL}s)."
    if ! sudo sh -c "pv -N 'Writing Image' -s \"$img_size\" -petrb -i \"$PV_UPDATE_INTERVAL\" \"$img_path\" | $DD_CMD"; then
        echo "Error during 'pv | dd' operation. Write may have failed."
        exit 1
    fi
else
    echo "Warning: 'pv' not found. Using OS-specific 'dd' progress."
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Using 'dd status=progress' on Linux."
        if ! sudo dd if="$img_path" $DD_CMD $DD_STATUS_PROGRESS; then
             echo "Error during 'dd' operation. Write may have failed."
             exit 1
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "On macOS without 'pv', 'dd' provides limited feedback. (Try Ctrl+T or 'sudo pkill -INFO -x dd')."
        if ! sudo dd if="$img_path" $DD_CMD; then
             echo "Error during 'dd' operation. Write may have failed."
             exit 1
        fi
    else
        echo "Unsupported OS for specific 'dd' progress. Attempting generic 'dd'."
        if ! sudo dd if="$img_path" $DD_CMD; then
             echo "Error during 'dd' operation. Write may have failed."
             exit 1
        fi
    fi
fi

echo "Syncing data to disk..."
if [[ "$OSTYPE" == "darwin"* ]]; then
    sync
    sync
else
    sudo sync
fi
sleep 3

echo ""
echo "--------------------------------------------------------------------"
echo "Write operation to $disk_name completed successfully."
echo "You can now try to safely eject or remove the disk."
if [[ "$OSTYPE" == "darwin"* ]]; then
    echo "On macOS, use Disk Utility or Finder to eject. (Cmd line: diskutil eject $disk_name)"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    echo "On Linux, ensure system activity has ceased. Desktop eject option or physical removal after sync."
fi
echo "--------------------------------------------------------------------"
