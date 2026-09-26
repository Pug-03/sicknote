# SickNote — ใบลาป่วยฉุกเฉินบนบล็อกเชน

โมดูลที่ 3 ของโปรเจกต์ Ultimate Sleep-Deprived Dev Assistant

## โครงสร้างไฟล์
```
├── contracts/EmergencySickLeave.sol   # Smart contract (Solidity ^0.8.20, self-contained)
├── index.html                         # UI หน้าเดียว + ethers.js v6 (ไม่ต้อง build)
└── foundry.toml                       # คอนฟิก Foundry สำหรับ compile / deploy
```

## 1) Deploy contract บน Avalanche Fuji

วิธีที่เร็วที่สุด (Remix, ไม่ต้องลงอะไรเลย):

1. เปิด https://remix.ethereum.org แล้วสร้างไฟล์ `EmergencySickLeave.sol` วางโค้ดลงไป
2. แท็บ **Solidity Compiler** → เลือก compiler `0.8.20` ขึ้นไป → เปิด **Enable optimization** (200 runs) → Compile
3. ขอ AVAX ทดสอบที่ https://faucet.avax.network (เลือก Fuji C-Chain)
4. แท็บ **Deploy & Run** → Environment = **Injected Provider - MetaMask** → ตรวจว่า MetaMask อยู่บน Fuji (Chain ID 43113) → กด **Deploy**
5. คัดลอก contract address ที่ได้

Constructor ไม่รับพารามิเตอร์ ผู้ deploy จะกลายเป็น `owner` อัตโนมัติ

## 2) รัน frontend

เปิด `index.html` ด้วยเบราว์เซอร์ที่มี MetaMask ได้ตรง ๆ (เปิดผ่าน `file://` ก็ใช้ได้)
หรือเสิร์ฟผ่าน local server:

```bash
python3 -m http.server 8080
# แล้วเปิด http://localhost:8080
```

### ทางเลือก: รันบน local chain ด้วย Foundry

```bash
anvil --chain-id 31337 --block-time 2
forge create contracts/EmergencySickLeave.sol:EmergencySickLeave \
  --rpc-url http://127.0.0.1:8545 --private-key <anvil test key> --broadcast
```

หน้าเว็บรองรับทั้ง Anvil Local (31337) และ Avalanche Fuji (43113) และขอให้ MetaMask
เพิ่ม/สลับเครือข่ายให้อัตโนมัติ

ขั้นตอนใช้งาน: วาง contract address → **เชื่อมต่อกระเป๋า** → ใส่เหตุผล → **Claim**

## 3) กลไกกันกดซ้ำ (2 ชั้น)

| ชั้น | กลไก | ป้องกันอะไร |
|---|---|---|
| 1 | `hasClaimed[msg.sender]` เช็กก่อนทำอย่างอื่น แล้วเซ็ต `true` ทันทีก่อนเขียน state อื่น | 1 address claim ได้ครั้งเดียวตลอดกาล กดซ้ำ revert ด้วย `AlreadyClaimed(claimer, claimedAt)` |
| 2 | `nonReentrant` modifier (สลับ `_status` 1 ↔ 2) | contract ที่พยายามเรียกวนซ้ำภายใน transaction เดียว |

ลำดับใน `claimSickLeave` ใช้แพตเทิร์น **Checks-Effects-Interactions**: เช็กเงื่อนไข → เขียน state → emit event
ฟังก์ชันนี้ไม่มี external call เลย จึงไม่มีช่อง reenter อยู่แล้ว — `nonReentrant` ใส่ไว้เป็น defense-in-depth เผื่อวันหลังเพิ่ม hook หรือ mint NFT ใบลา

ใช้ custom error แทน `require(string)` เพื่อประหยัด gas และให้ frontend ถอดรหัสสาเหตุ revert ได้ตรง ๆ
(ต้องประกาศ error เหล่านั้นใน ABI ฝั่ง frontend ด้วย ไม่งั้น ethers อ่านไม่ออก)

## 4) ฟังก์ชันที่มี

**ผู้ใช้ทั่วไป**
- `claimSickLeave(string reason)` — claim ใบลา + รับ 100 แต้ม คืนค่า `ticketId`
- `canClaim(address)` / `hasClaimed(address)` / `survivorPoints(address)` / `getRecord(address)` — view ฟรี
- `totalTickets()` / `totalClaimers()` / `getClaimers(offset, limit)` — สถิติรวม (แบ่งหน้าเพื่อกัน out-of-gas)

**owner เท่านั้น**
- `setPaused(bool)` — หยุด/เปิดรับ claim
- `revokeClaim(address)` — ล้างสิทธิ์ให้ claim ใหม่ได้ (ใช้ตอน demo ซ้ำ) และหักพอยต์คืน
- `transferOwnership(address)`

## 5) จุดที่ frontend ทำให้ UX ไม่เสีย gas ทิ้ง

ก่อนส่ง transaction จริง หน้าเว็บเรียก `staticCall` เพื่อ simulate ก่อน — ถ้าจะ revert (เช่นเคย claim ไปแล้ว)
ผู้ใช้จะเห็นข้อความทันทีโดยไม่เสีย gas เลย จากนั้นค่อย `estimateGas` (เผื่อ 20%) แล้วส่งจริง
สถานะแสดง 4 ขั้น: simulate → รอลายเซ็น → ส่งเข้า mempool (มีลิงก์ Snowtrace) → ยืนยันแล้ว

## หมายเหตุ
สัญญานี้ไม่มี `receive()` / `payable` จึงรับ AVAX ไม่ได้และไม่ถือเงินใด ๆ — ไม่มีความเสี่ยงเรื่องเงินถูกดูด
โค้ดนี้เขียนเพื่อใช้บน **testnet** ยังไม่ผ่าน audit อย่าเอาไป deploy mainnet โดยไม่ตรวจซ้ำ
