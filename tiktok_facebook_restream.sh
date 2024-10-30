#!/bin/bash

# File: tiktok_facebook_restream.sh
# Description: Script untuk restreaming TikTok Live ke Facebook dengan fitur monitoring
# Last Updated: 2024-10-29

###################
# File Locations #
###################
CONFIG_DIR="/etc/restream"
LOG_DIR="/var/log/restream"
TEMP_DIR="/tmp/restream"
CONFIG_FILE="${CONFIG_DIR}/config.env"
LOG_FILE="${LOG_DIR}/tiktok_restream.log"
PID_FILE="${TEMP_DIR}/restream.pid"
RATE_LIMIT_FILE="${TEMP_DIR}/rate_limit"

###################
# Setup Directory #
###################
setup_directories() {
    for dir in "$CONFIG_DIR" "$LOG_DIR" "$TEMP_DIR"; do
        [ ! -d "$dir" ] && mkdir -p "$dir"
    done
    touch "$LOG_FILE"
    chmod 640 "$LOG_FILE"
}

###################
# Load Config #
###################
create_default_config() {
    cat > "$CONFIG_FILE" << EOF
# Konfigurasi Umum
TIMEOUT=30
MAX_RETRIES=3
RETRY_INTERVAL=60

# TikTok Configuration
TIKTOK_LIVE_URL="https://www.tiktok.com/<usernameTiktok>/live"

# Facebook Configuration
FACEBOOK_RTMP_URL="rtmps://live-api-s.facebook.com:443/rtmp/<KEY>"

# Watermark Configuration
WATERMARK_TEXT="Restreaming Tiktok <username>"
WATERMARK_FONT="/usr/share/fonts/dejavu-sans-fonts/DejaVuSans-Oblique.ttf"

# Telegram Configuration
SEND_TELEGRAM=true
TELEGRAM_TOKEN="<ID-TOKEN>"
TELEGRAM_CHAT_ID="<ID-CHAT>"

# FFmpeg Configuration
FFMPEG_VIDEO_BITRATE="2500k"
FFMPEG_BUFFER_SIZE="5000k"
FFMPEG_GOP_SIZE="60"
FFMPEG_AUDIO_BITRATE="128k"
EOF
    chmod 600 "$CONFIG_FILE"
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_message "INFO" "Config file not found, creating default config..."
        create_default_config
        log_message "ERROR" "Please edit $CONFIG_FILE with your settings"
        exit 1
    fi
    source "$CONFIG_FILE"
}

###################
# Logging Functions #
###################
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    if [ -t 1 ]; then
        echo "[$timestamp] [$level] $message"
    fi
    
    if [ "$level" == "ERROR" ] && [ "$SEND_TELEGRAM" = true ]; then
        send_to_telegram "[ERROR] $message" ""
    fi
}

###################
# Validation Functions #
###################
validate_url() {
    local url="$1"
    if [[ $url =~ ^https?://([a-zA-Z0-9.-]+\.[a-zA-Z]{2,})(:[0-9]+)?(/.*)?$ ]]; then
        return 0
    fi
    return 1
}

validate_dependencies() {
    local deps=("ffmpeg" "curl" "jq")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            log_message "ERROR" "Required dependency '$dep' is not installed"
            exit 1
        fi
    done
}

check_font() {
    if [ ! -f "$WATERMARK_FONT" ]; then
        log_message "ERROR" "Font not found: $WATERMARK_FONT"
        log_message "INFO" "Available fonts:"
        fc-list : file
        exit 1
    fi
}

###################
# Telegram Functions #
###################
send_to_telegram() {
    local message="${1//\"/\\\"}"
    local cover_url="$2"
    local request_data
    local api_endpoint

    if [ -n "$cover_url" ]; then
        request_data="{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"photo\":\"$cover_url\",\"caption\":\"$message\"}"
        api_endpoint="sendPhoto"
    else
        request_data="{\"chat_id\":\"$TELEGRAM_CHAT_ID\",\"text\":\"$message\"}"
        api_endpoint="sendMessage"
    fi

    local response
    response=$(curl -s -m "$TIMEOUT" -X POST "https://api.telegram.org/bot$TELEGRAM_TOKEN/$api_endpoint" \
        -H "Content-Type: application/json" \
        -d "$request_data")

    if [[ "$response" == *"\"ok\":true"* ]]; then
        log_message "INFO" "Telegram message sent successfully"
    else
        log_message "ERROR" "Failed to send Telegram message: $response"
    fi
}

###################
# TikTok Functions #
###################
get_room_id() {
    local live_url="$1"
    local response
    local room_id
    
    response=$(curl -s -m "$TIMEOUT" \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" \
        "$live_url")
    
    room_id=$(echo "$response" | grep -oP 'roomId["\s:=]+\K[0-9]+' | head -1)
    
    if [ -z "$room_id" ]; then
        room_id=$(echo "$response" | grep -oP '"roomId":"[0-9]+"' | cut -d'"' -f4 | head -1)
    fi
    
    echo "$room_id"
}

###################
# Streaming Functions #
###################
check_available_encoders() {
    log_message "INFO" "Checking available encoders..."
    
    # Check if VAAPI device exists and is accessible
    if [ -e "/dev/dri/renderD128" ] && [ -r "/dev/dri/renderD128" ]; then
        # Test VAAPI functionality
        if ffmpeg -vaapi_device /dev/dri/renderD128 -f lavfi -i testsrc -t 1 -c:v h264_vaapi -f null - 2>/dev/null; then
            log_message "INFO" "VAAPI encoder available"
            echo "h264_vaapi"
            return
        fi
    fi
    
    # Check NVENC (NVIDIA)
    if nvidia-smi &>/dev/null && ffmpeg -encoders 2>/dev/null | grep -q h264_nvenc; then
        log_message "INFO" "NVENC encoder available"
        echo "h264_nvenc"
        return
    fi
    
    # Check QSV (Intel QuickSync)
    if [ -e "/dev/dri/renderD128" ] && ffmpeg -encoders 2>/dev/null | grep -q h264_qsv; then
        log_message "INFO" "QSV encoder available"
        echo "h264_qsv"
        return
    fi
    
    # Default to software encoding
    log_message "INFO" "Using software encoding (h264)"
    echo "h264"
}

start_streaming() {
    local live_url="$1"
    local ffmpeg_log="${LOG_DIR}/ffmpeg_debug.log"
    local encoder=$(check_available_encoders)
    
    log_message "INFO" "Starting FFmpeg with encoder: $encoder"
    
    case $encoder in
        "h264_vaapi")
            if [ -e "/dev/dri/renderD128" ] && [ -r "/dev/dri/renderD128" ]; then
                ffmpeg -i "$live_url" \
                    -vf "drawtext=fontfile=${WATERMARK_FONT}:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=(w-tw-10):y=10:text='${WATERMARK_TEXT}'" \
                    -c:v h264_vaapi -preset veryfast \
                    -b:v "$FFMPEG_VIDEO_BITRATE" -maxrate "$FFMPEG_VIDEO_BITRATE" -bufsize "$FFMPEG_BUFFER_SIZE" \
                    -g "$FFMPEG_GOP_SIZE" -keyint_min "$FFMPEG_GOP_SIZE" \
                    -c:a aac -b:a "$FFMPEG_AUDIO_BITRATE" \
                    -f flv "$FACEBOOK_RTMP_URL" 2>> "$ffmpeg_log" &
            else
                log_message "WARNING" "VAAPI device not available, falling back to software encoding"
                encoder="h264"
            fi
            ;;
            
        "h264_nvenc")
            ffmpeg -i "$live_url" \
                -vf "drawtext=fontfile=${WATERMARK_FONT}:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=(w-tw-10):y=10:text='${WATERMARK_TEXT}'" \
                -c:v h264_nvenc -preset p1 -tune ll \
                -b:v "$FFMPEG_VIDEO_BITRATE" -maxrate "$FFMPEG_VIDEO_BITRATE" -bufsize "$FFMPEG_BUFFER_SIZE" \
                -g "$FFMPEG_GOP_SIZE" -keyint_min "$FFMPEG_GOP_SIZE" \
                -c:a aac -b:a "$FFMPEG_AUDIO_BITRATE" \
                -f flv "$FACEBOOK_RTMP_URL" 2>> "$ffmpeg_log" &
            ;;
        
        *)
            # Software encoding
            ffmpeg -i "$live_url" \
                -vf "drawtext=fontfile=${WATERMARK_FONT}:fontsize=24:fontcolor=white:box=1:boxcolor=black@0.5:boxborderw=5:x=(w-tw-10):y=10:text='${WATERMARK_TEXT}'" \
                -c:v h264 -preset ultrafast -tune zerolatency \
                -b:v "$FFMPEG_VIDEO_BITRATE" -maxrate "$FFMPEG_VIDEO_BITRATE" -bufsize "$FFMPEG_BUFFER_SIZE" \
                -g "$FFMPEG_GOP_SIZE" -keyint_min "$FFMPEG_GOP_SIZE" \
                -c:a aac -b:a "$FFMPEG_AUDIO_BITRATE" \
                -f flv "$FACEBOOK_RTMP_URL" 2>> "$ffmpeg_log" &
            ;;
    esac
    
    FFMPEG_PID=$!
    echo $FFMPEG_PID > "$PID_FILE"
    
    sleep 5
    if ! ps -p $FFMPEG_PID > /dev/null; then
        log_message "ERROR" "FFmpeg failed to start. Check $ffmpeg_log for details"
        return 1
    fi
    
    log_message "INFO" "FFmpeg started with PID: $FFMPEG_PID using encoder $encoder"
}

check_stream_health() {
    local cpu_usage
    local mem_usage
    
    cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}')
    mem_usage=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    
    if (( $(echo "$cpu_usage > 90" | bc -l) )); then
        log_message "WARNING" "High CPU usage: $cpu_usage%"
        send_to_telegram "⚠️ High CPU usage: $cpu_usage%" ""
    fi
    
    if (( $(echo "$mem_usage > 85" | bc -l) )); then
        log_message "WARNING" "High memory usage: $mem_usage%"
        send_to_telegram "⚠️ High memory usage: $mem_usage%" ""
    fi
}

monitor_stream() {
    local retries=0
    while true; do
        if [ ! -f "$PID_FILE" ] || ! ps -p "$(cat "$PID_FILE")" > /dev/null; then
            log_message "WARNING" "FFmpeg process died"
            
            if [ $retries -lt $MAX_RETRIES ]; then
                retries=$((retries+1))
                log_message "INFO" "Attempting restart ($retries/$MAX_RETRIES)"
                send_to_telegram "🔄 Restreaming stopped. Attempting restart ($retries/$MAX_RETRIES)" ""
                fetch_tiktok_live_data_and_restream
                sleep "$RETRY_INTERVAL"
            else
                log_message "ERROR" "Max retries reached. Stopping monitoring."
                send_to_telegram "❌ Restreaming failed after $MAX_RETRIES attempts. Please check manually." ""
                break
            fi
        else
            log_message "INFO" "Stream is running normally"
            check_stream_health
        fi
        sleep 30
    done
}

###################
# Cleanup Functions #
###################
cleanup() {
    log_message "INFO" "Cleaning up..."
    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if ps -p "$pid" > /dev/null; then
            kill -15 "$pid"
            wait "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi
    rm -f "$RATE_LIMIT_FILE"
    log_message "INFO" "Cleanup completed"
}

stop_all_processes() {
    log_message "INFO" "Stopping all related processes..."
    
    if pgrep -f "tiktok_facebook_restream.sh" > /dev/null; then
        log_message "INFO" "Stopping script instances..."
        pkill -f "tiktok_facebook_restream.sh"
    fi
    
    if pgrep "ffmpeg" > /dev/null; then
        log_message "INFO" "Stopping FFmpeg processes..."
        killall ffmpeg
    fi
    
    rm -f "$PID_FILE"
    log_message "INFO" "All processes stopped"
}

###################
# Main Function #
###################
fetch_tiktok_live_data_and_restream() {
    local room_id
    room_id=$(get_room_id "$TIKTOK_LIVE_URL")
    
    if [ -z "$room_id" ]; then
        log_message "ERROR" "Could not retrieve roomId from TikTok live link"
        return 1
    fi
    
    local api_url="https://www.tiktok.com/api/live/detail/?aid=1988&roomID=$room_id"
    local response
    response=$(curl -s -m "$TIMEOUT" \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36" \
        "$api_url")
		# Lanjutan dari fetch_tiktok_live_data_and_restream()
    local status_code
    status_code=$(echo "$response" | jq -r '.status_code')
    
    if [ "$status_code" != "0" ]; then
        log_message "ERROR" "Error fetching data from TikTok API: $(echo "$response" | jq -r '.status_msg')"
        return 1
    fi
    
    local now_timestamp
    local now_formatted
    local status
    local status_text
    local cover_url
    local signature
    local nickname
    local unique_id
    local live_url
    
    now_timestamp=$(echo "$response" | jq -r '.extra.now')
    now_formatted=$(date -d @$((now_timestamp / 1000)) '+%A, %d %B %Y %H:%M:%S')
    status=$(echo "$response" | jq -r '.LiveRoomInfo.status')
    status_text=$([ "$status" == "2" ] && echo "🟢 ONLINE" || echo "🔴 OFFLINE")
    cover_url=$(echo "$response" | jq -r '.LiveRoomInfo.coverUrl')
    signature=$(echo "$response" | jq -r '.LiveRoomInfo.ownerInfo.signature')
    nickname=$(echo "$response" | jq -r '.LiveRoomInfo.ownerInfo.nickname')
    unique_id=$(echo "$response" | jq -r '.LiveRoomInfo.ownerInfo.uniqueId')
    live_url=$(echo "$response" | jq -r '.LiveRoomInfo.liveUrl')
    
    local message="Status: $status_text
Time: $now_formatted
Room ID: $room_id
Channel: $nickname ($unique_id)
Description: $signature"
    
    if [ "$SEND_TELEGRAM" = true ]; then
        send_to_telegram "$message" "$cover_url"
    fi
    
    if [ "$status" == "2" ]; then
        if [ ! -f "$PID_FILE" ] || ! ps -p "$(cat "$PID_FILE")" > /dev/null; then
            start_streaming "$live_url"
            monitor_stream &
        else
            log_message "INFO" "Stream is already running"
        fi
    else
        log_message "INFO" "TikTok live is offline"
    fi
}

main() {
    # Setup trap for cleanup
    trap cleanup EXIT INT TERM
    
    # Initial setup
    setup_directories
    load_config
    validate_dependencies
    check_font
    
    # Check command line arguments
    case "$1" in
        "troubleshoot")
            log_message "INFO" "Starting troubleshooting..."
            if pgrep -f "tiktok_facebook_restream.sh" > /dev/null; then
                stop_all_processes
            fi
            validate_dependencies
            check_font
            check_available_encoders
            exit $?
            ;;
        "stop")
            stop_all_processes
            exit 0
            ;;
        "status")
            if [ -f "$PID_FILE" ] && ps -p "$(cat "$PID_FILE")" > /dev/null; then
                echo "Stream is running with PID: $(cat "$PID_FILE")"
                exit 0
            else
                echo "Stream is not running"
                exit 1
            fi
            ;;
        "clean")
            cleanup
            exit 0
            ;;
        *)
            # Normal operation
            log_message "INFO" "Starting TikTok to Facebook restreaming service"
            while true; do
                fetch_tiktok_live_data_and_restream
                sleep 60
            done
            ;;
    esac
}

# Start the script
main "$@"
