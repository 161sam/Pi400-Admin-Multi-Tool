# Pi400-Admin-Multi-Tool
Das Projekt umfasst ein Pi400 als Admin-Multi-Tool für Systemadministratoren, Netzwerk- und Security-Techniker, basierend auf Kali Linux
---

## **Projektübersicht**

Das Projekt ist ein **Pi400 Admin-Multi-Tool** für Systemadministratoren, Netzwerk- und Security-Techniker, basierend auf **Kali Linux (Headless, mit kleinem Touch-Display)**. Es ermöglicht:

* **HID-Injection** (z. B. Notfall-Makros, automatisierte Tastatureingaben)
* **Serial-Konsole** (bidirektional)
* **USB-Gadget-Modi** (HID, CDC-ACM Serial, RNDIS/ECM Ethernet)
* **Auto-SSH und Terminal-Befehle** via USB/Ethernet (Plug & Play)
* **PXE-/Netboot-Server** (TFTP + HTTP-Boot, NFS für Images)
* **Massenspeicher-Tools** (Flashen, Klonen, Verifizieren, Backup von Devices)
* **Vault** (Password Store via `pass` + YubiKey)
* **Admin Panel (Rust/Iced GUI)** mit nativer Touch-Unterstützung
* **Kiosk-Modus für Pi400-Display**
* **Erweiterbar für Kali-Werkzeuge und Automationen**

---

## **Architektur**

### **1. Hardware**

* Raspberry Pi 400 (USB-C für Gadget-Funktion)
* Multi-Touch-HDMI/SPI-Display
* GPIO für Stromversorgung optional

### **2. Betriebssystem**

* **Kali Linux (CLI)**, ohne Desktop
* Minimaler X-Stack für Kiosk GUI:

  * `xserver-xorg`, `xinit`, `matchbox-window-manager`, `unclutter`

### **3. Services**

* **`admin-backend`** (Rust, REST API via Unix-Domain-Socket)
* **`admin-panel-iced`** (Rust/Iced GUI im Kiosk)
* **`pi400-hid`**: HID-Injection über `/dev/hidg0`
* **`target-serial-tcp`**: TCP→Serial Bridge (Port 5555 → `/dev/ttyGS0`)
* **`pxe-server.target`**: startet `dnsmasq` + `nfs-kernel-server`
* **`pxe-http.target`**: startet `nginx` für HTTP-Boot
* **`udev` Rule für Auto-Refresh bei USB-Medien**
* **`media-bump.sh`**: erzeugt Trigger-Datei für GUI-Refresh

### **4. Backends**

* **Rust/Axum API**:

  * Service-Management via `systemctl`
  * USB Gadget Setup (HID/Serial/Ethernet)
  * HID-Handling via Python-Script (`hid-type.py`)
  * Vault-Integration: `pass`, YubiKey
  * PXE-Menü-Editor, TFTP-Tree, HTTP-Boot-Config
  * Medienfunktionen:

    * `lsblk` JSON → UI-Tabelle
    * Flash Image → Device (`pv` + `dd`)
    * Device → Device Clone
    * Verify (cmp oder SHA256)
    * Device → Image Backup (optional komprimiert)
    * Copy Files → USB
* **Status-Files** für Flash/Clone-Progress (`/run/pi400-admin/*.status`)

### **5. Frontend (Admin Panel)**

* **Rust/Iced** (Dark Theme, Fullscreen 800x480)
* **Tabs**:

  * **Services**: Start/Stop/Enable für `pi400-hid`, `target-serial-tcp`, PXE, HTTP-Boot
  * **Network**: NAT-Toggle, Uplink-Wahl, TARGET-IP
  * **Tools**: HID-Eingabe, Makros (z. B. `enable_root`, `iface_up`)
  * **Logs**: Journal-Ausschnitt mit Auto-Update
  * **Serial**: Bidirektionale Konsole
  * **Vault**: Pass-Integration (Auto-Mask)
  * **Actions**: Token-gesicherte Aktionen (z. B. Update)
  * **PXE**:

    * Service-Buttons
    * Menü-Editor für `pxelinux.cfg/default`
    * PXE-Wizard: ISO/Archive entpacken, Menü-Eintrag auto hinzufügen
    * TFTP-Tree, Leases, Logs
  * **Media**:

    * Gerätetabelle (`lsblk -J` → Tabelle)
    * **Flash**: Image → Device (mit Confirm + SHA256 optional)
    * **Clone**: Device → Device
    * **Verify**: Image vs. Device
    * **Backup**: Device → Image (mit Kompression)
    * **Copy**: Files → USB-Mount
    * Fortschrittsanzeige (`pv` → Status)

---

## **Dateistruktur**

```
/opt/pi400-admin/
├── backend/             # Rust (Axum) API
│   ├── src/main.rs      # Hauptrouter + Handlers
│   ├── media_*patch.rs  # Extra Handler (Clone, Backup, Status)
├── frontend-iced/       # Rust/Iced GUI
│   └── src/main.rs      # Vollständiges UI
├── scripts/
│   ├── pi400-composite.sh
│   ├── nat-toggle.sh
│   ├── target-ip
│   ├── hid-type.py
│   └── media-bump.sh
├── systemd/
│   ├── admin-backend.service
│   ├── kiosk.service
│   ├── pxe-server.target
│   ├── pxe-http.target
├── nginx/sites-available/pxe.conf
└── udev/99-pi400-media.rules
```

---

## **Abhängigkeiten**

```bash
apt-get install -y --no-install-recommends \
  xserver-xorg xinit x11-xserver-utils xinput xrandr \
  matchbox-window-manager unclutter \
  autossh socat nftables \
  python3 python3-venv \
  pass gnupg rng-tools yubikey-manager \
  git build-essential pkg-config libssl-dev \
  curl ca-certificates \
  dnsmasq nfs-kernel-server pxelinux syslinux-common \
  pv xz-utils gzip parted dosfstools rsync nginx bsdtar
```

---

## **Wichtige Features**

✔ **Plug & Play**: Pi400 → TARGET via USB-C → HID/Serial/Ethernet
✔ **GUI für alle Tasks** (Touch-freundlich, Tab-Struktur)
✔ **Auto-Refresh** bei Medienwechsel (udev-basiert)
✔ **Progress-Anzeige** für Flash, Clone, Backup
✔ **Sicherheitsmechanismen**:

* Admin-PIN
* Consent-Token für gefährliche Aktionen
* X-Confirm Header bei destruktiven Operationen
  ✔ **PXE-Wizard**: ISO/Archive entpacken, Menü-Eintrag hinzufügen
  ✔ **Vault** mit YubiKey-Integration
  ✔ **Logs & Serial direkt in der GUI**

---

## **Nächste Schritte**

1. **Build-Anleitung erstellen**:
   * Rust cross-compilation für ARM64
   * Systemd-Units installieren
   * Kiosk-Autostart
  
2. **Test-Szenarien**:
   * USB-Gadget (HID/Serial/Ethernet) unter Linux, Windows, macOS
   * PXE-Boot auf Clients
   * Medien-Operationen auf SD-Karten/USB-Sticks
  
3. **Erweiterungen**:
   * VT-Terminal-Emulator für Serial
   * Mehr HID-Makros (Layout-aware)
   * GPG-Integration für Vault
   * Optionales **HTTP-Dashboard** parallel zur GUI
   * API für mobile Steuerung (REST/WebSocket)

---

