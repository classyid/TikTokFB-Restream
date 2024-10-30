# TikTokFB-Restream
🔄 Script Bash untuk restreaming otomatis dari TikTok Live ke Facebook Live dengan monitoring status dan notifikasi Telegram.

## 🌟 Fitur Utama
- Restreaming otomatis dari TikTok Live ke Facebook Live
- Hardware acceleration support (VAAPI, NVENC, QSV)
- Monitoring status stream real-time
- Notifikasi Telegram untuk status dan error
- Watermark text overlay
- Auto-retry saat stream terputus
- Resource monitoring (CPU/RAM)

## 🛠️ Prasyarat
- FFmpeg
- curl
- jq
- Font DejaVu Sans (atau font lain yang didukung)
- Akses ke API Telegram (opsional)

## ⚙️ Instalasi
1. Clone repository:
```bash
git clone https://github.com/yourusername/tiktokfb-restream
cd tiktokfb-restream
```

2. Buat file konfigurasi:
```bash
sudo mkdir -p /etc/restream
sudo cp config.env.example /etc/restream/config.env
```

3. Edit konfigurasi:
```bash
sudo nano /etc/restream/config.env
```

## 🚀 Penggunaan
### Menjalankan Restream
```bash
./tiktok_facebook_restream.sh
```

### Perintah Tambahan
- Status: `./tiktok_facebook_restream.sh status`
- Stop: `./tiktok_facebook_restream.sh stop`
- Troubleshoot: `./tiktok_facebook_restream.sh troubleshoot`
- Cleanup: `./tiktok_facebook_restream.sh clean`
