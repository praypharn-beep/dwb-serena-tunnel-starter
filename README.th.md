# DWB Serena Tunnel Starter — คู่มือภาษาไทย

ชุดเริ่มต้นสำหรับ Windows เพื่อเชื่อม **ChatGPT → OpenAI Secure MCP Tunnel → Serena → โปรเจกต์ในเครื่อง** โดยไม่ต้องเปิด MCP server ให้เข้าถึงจากอินเทอร์เน็ตโดยตรง

> Community starter โดย **Dev with Bebz** ไม่ใช่ซอฟต์แวร์ทางการของ OpenAI หรือ Serena
>
> 🎥 วิดีโอสาธิต: https://youtu.be/18S_QaMpUtY

คู่มือภาษาอังกฤษ: **[README.md](README.md)**

## สิ่งที่ต้องมี

- Windows 10/11 แบบ x64 หรือ ARM64
- PowerShell 5.1 ขึ้นไป
- `uv`
- Serena ที่ติดตั้งและ `serena init` แล้ว
- Tunnel ID จาก OpenAI Platform
- Runtime API key ที่ใช้ tunnel ได้
- สิทธิ์ **Tunnels Read + Use**
- สิทธิ์ใช้ developer mode ใน ChatGPT workspace เป้าหมาย

## 1. ติดตั้ง Serena

```powershell
uv tool install -p 3.13 serena-agent
serena init
serena --help
```

ถ้าคำสั่งสุดท้ายทำงานไม่ได้ ให้ซ่อม Serena ก่อนรัน Starter นี้

## 2. เตรียม Tunnel ID และ Runtime API key

เปิด [OpenAI Platform tunnel settings](https://platform.openai.com/settings/organization/tunnels) แล้วสร้างหรือเลือก tunnel ที่ผูกกับ Platform organization และ ChatGPT workspace ที่ต้องการใช้งาน

- การสร้างหรือแก้ tunnel ต้องมี **Tunnels Read + Manage**
- การรัน tunnel-client และเลือก tunnel ใน ChatGPT ต้องมี **Tunnels Read + Use**
- ใช้ **Runtime API key** กับโปรแกรมนี้ ห้ามใช้ Admin API key กับ daemon
- Tunnel ID ต้องอยู่ในรูป `tunnel_` ตามด้วยเลขฐานสิบหกตัวเล็ก 32 ตัว

## 3. ดาวน์โหลดและ Setup

ดาวน์โหลด ZIP จาก GitHub แล้วแตกไฟล์ไว้ที่ใดก็ได้ จากนั้นดับเบิลคลิก:

```text
Setup.cmd
```

โปรแกรมจะ:

1. ตรวจว่า Serena เปิดได้จริง
2. ดาวน์โหลด tunnel-client รุ่น stable ล่าสุดจาก `openai/tunnel-client`
3. ตรวจ SHA-256 เมื่อ release มี `SHA256SUMS.txt`
4. ขอ Tunnel ID และ Runtime API key
5. เข้ารหัส API key ด้วย Windows DPAPI

ข้อมูลในเครื่องถูกเก็บที่:

```text
config\team.ps1
config\api-key.dpapi
```

ทั้งสองไฟล์ถูกกันออกจาก Git แล้ว ห้าม force-add หรือส่งไฟล์เหล่านี้ให้ผู้อื่น

## 4. เริ่มใช้งาน

ดับเบิลคลิก:

```text
Start.cmd
```

โปรแกรมจะรัน preflight ด้วย `tunnel-client doctor --explain` ก่อน ถ้าผ่านจึงจะเปิด tunnel จากนั้นดูสถานะได้ที่:

```text
http://127.0.0.1:18010/ui
```

เปิดหน้าต่าง `Start.cmd` ค้างไว้ระหว่างใช้งาน และปิดหน้าต่างเมื่อเลิกใช้

## 5. เชื่อมใน ChatGPT

เมื่อหน้า status แสดงว่า tunnel พร้อมใช้งาน:

1. เปิด developer mode ของ ChatGPT workspace
2. ไปที่ [ChatGPT Plugins](https://chatgpt.com/plugins)
3. กดปุ่มเพิ่มเพื่อสร้าง developer-mode app
4. เลือก **Tunnel** ในส่วน **Connection**
5. เลือก tunnel จากรายการ หรือวาง Tunnel ID

ถ้าไม่เห็น tunnel ให้ตรวจว่า tunnel ผูกกับ ChatGPT workspace ถูกตัว บัญชีมี **Tunnels Read + Use** และ developer mode เปิดอยู่

## 6. เลือกโปรเจกต์ในเครื่อง

Starter ไม่ล็อก path ของโปรเจกต์ไว้ เพื่อให้ใช้ได้หลายโปรเจกต์ ตอนเริ่มแชตให้ระบุ path ที่ต้องการอย่างชัดเจน เช่น:

```text
ใช้ Serena activate โปรเจกต์ C:\work\my-project แล้วแสดง current Serena configuration ให้ตรวจสอบก่อน
```

ตรวจ path ที่ Serena รายงานกลับมาก่อนสั่งอ่านหรือแก้ไฟล์ Serena ทำงานกับ coding project ที่ active อยู่ครั้งละหนึ่งโปรเจกต์

## 7. ทดลองตามวิดีโอ

ใช้ prompt ตัวอย่างที่ [FlowPilot AI Landing Page](examples/flowpilot-ai-landing-page.md) เพื่อตรวจตั้งแต่การเชื่อมต่อจนถึงการสร้างไฟล์ในโปรเจกต์

## การใช้งานประจำวัน

- ปกติรันเพียง `Start.cmd`
- ใช้ `Configure.cmd` เมื่อต้องการเปลี่ยน Tunnel ID หรือ Runtime API key
- ใช้ `Setup.cmd` เมื่อต้องการอัปเดต tunnel-client รุ่นล่าสุดและตั้งค่า credential ใหม่
- ปิด `Start.cmd` ทุกครั้งเมื่อเลิกใช้งาน

## Serena เริ่มทำงานแบบ on-demand (lazy start)

`Start.cmd` ไม่ได้เปิด Serena โดยตรงอีกต่อไป แต่จะ render tunnel profile ที่ให้ MCP command เป็น lazy proxy ตัวเล็ก (`lazy-proxy/cli.mjs`) คั่นกลางระหว่าง `tunnel-client` กับ Serena:

```text
ChatGPT → tunnel-client → lazy proxy → Serena (เริ่มเมื่อจำเป็น)
```

- **tunnel และ proxy ทำงานค้างไว้ตลอด** ตราบใดที่ `Start.cmd` (หรือชุดควบคุม lazy ด้านล่าง) ยังทำงานอยู่ มีเพียง **process ของ Serena เท่านั้น** ที่เป็นแบบ lazy
- Serena **จะไม่เริ่ม** ตอนเปิด `Start.cmd`, ตอน ChatGPT เชื่อมต่อ, หรือตอนเรียก `tools/list` แต่จะเริ่มเมื่อมี **`tools/call` จริงครั้งแรก**
- Serena ทำงานแบบ **singleton** — คำขอที่เข้ามาพร้อมกันจะถูกต่อคิวไปที่ Serena instance เดียว ไม่เปิดตัวที่สอง
- Serena จะ **หยุดเองอัตโนมัติหลังไม่มีการใช้งาน 15 นาที** (`900000` ms) และเริ่มใหม่เมื่อมีการเรียกใช้เครื่องมือจริงครั้งถัดไป การเรียกครั้งแรกหลัง Serena หยุดหรือยังไม่เคยเริ่มอาจมีดีเลย์สั้น ๆ (ปกติไม่กี่วินาที ไม่เกิน startup timeout 30 วินาที)
- **ไม่มีการ activate โปรเจกต์อัตโนมัติ** การเลือกโปรเจกต์ยังคงเป็นขั้นตอนที่ต้องสั่งจาก ChatGPT เอง (ดูข้อ 6 ด้านบน) ไม่ว่า Serena จะกำลังทำงานอยู่หรือไม่
- Tool manifest ของ lazy proxy ถูกจับภาพ (capture) จาก Serena ที่ติดตั้งในเครื่องครั้งเดียวและมีเลขเวอร์ชันกำกับ ถ้า tool set จริงของ Serena ไม่ตรงกับ manifest ที่จับไว้ proxy ยังทำงานต่อได้แต่จะรายงาน `manifestCompatible: false` ในสถานะ เพื่อให้ทราบว่าต้อง capture manifest ใหม่

### URL ตรวจสุขภาพและสถานะ

| URL | แสดงอะไร |
| --- | --- |
| `http://127.0.0.1:18010/ui` | สถานะการเชื่อมต่อ tunnel (เหมือนเดิม) |
| `http://127.0.0.1:18012/status` | สถานะ JSON ของ lazy proxy: `proxy`, `serena` (สถานะ), `pid`, `inFlight`, `queued`, `lastActivityAt`, `idleDeadline`, `manifestVersion`, `manifestCompatible`, `lastError` |

ทั้งสอง listener ผูกกับ `127.0.0.1` เท่านั้น และ status endpoint จะไม่คืนค่า secret, argument/ผลลัพธ์ของ tool หรือข้อมูลโปรเจกต์เด็ดขาด

### หมายเหตุความเสถียรของ `Start.cmd`

ขั้นตอน preflight และการเปิด tunnel ของ `Start.cmd` ใช้ bounded restart supervisor ตัวเดียวกับชุดควบคุม lazy ด้านล่าง native child process (`tunnel-client.exe`) ที่เขียนลง stderr ของตัวเองจะไม่ถูกเข้าใจผิดว่าเป็น PowerShell error และทำให้หน้าต่างปิดก่อนเวลาอีกต่อไป

## เปิดอัตโนมัติตอน logon (`Lazy-Control.cmd`)

สำหรับการใช้งานแบบไม่ต้องเปิดหน้าต่างค้างไว้ (tunnel/proxy พร้อมใช้ทันทีที่ล็อกอิน โดยไม่ต้องเปิด `Start.cmd` ทิ้งไว้) ให้ใช้ `Lazy-Control.cmd` แทน `Start.cmd`:

```text
Lazy-Control.cmd install     ลงทะเบียน logon task ของผู้ใช้ปัจจุบัน ให้เปิด supervisor แบบซ่อนหน้าต่าง
Lazy-Control.cmd start       เปิด tunnel/proxy supervisor ทันที โดยไม่ติดตั้ง auto-start
Lazy-Control.cmd status      แสดงสถานะ tunnel/proxy/Serena (PID, URL ตรวจสุขภาพ, idle deadline) โดยไม่มี secret
Lazy-Control.cmd stop        หยุด tunnel/proxy
Lazy-Control.cmd uninstall   ถอด logon task, หยุดการทำงาน, และคืนค่า tunnel profile ก่อนหน้า
```

รายละเอียด:

- Logon task ชื่อ **`DWB Serena Lazy Tunnel`** ทำงานเมื่อผู้ใช้ Windows คนปัจจุบัน logon (`AtLogOn`) เท่านั้น เปิดหน้าต่าง PowerShell แบบ **ซ่อน** และลงทะเบียนด้วยสิทธิ์ **ไม่ยกระดับ (Limited)** — ไม่ขอสิทธิ์ผู้ดูแลระบบเด็ดขาด
- `install` และ `start` render tunnel profile จาก template เดียวกับที่ `Start.cmd` ใช้ ดังนั้น profile จะชี้ไปที่ lazy proxy เสมอ ไม่ใช่ Serena โดยตรง
- `install` จะ **สำรอง (backup) tunnel profile ปัจจุบันก่อนเสมอ** ไปที่ `%APPDATA%\tunnel-client\backups\dwb-serena.<UTC timestamp>.yaml` (เช่น `dwb-serena.20260821T100000Z.yaml`) ก่อนเขียนทับ
- `stop` และ `uninstall` จะ **ตรวจ executable path และ command line** ของ process ที่จะหยุดก่อนส่งสัญญาณใด ๆ และตรวจซ้ำอีกครั้งก่อน force-kill เสมอ PID ที่หายไป ค้าง หรือถูกใช้ซ้ำโดย process อื่นจะถูกปล่อยไว้เฉย ๆ ไม่ถูกแตะต้อง ดูรายละเอียดที่ [SECURITY.md](SECURITY.md)
- `status` จะไม่แตะหรือแสดง API key ที่ถอดรหัสแล้วเด็ดขาด

### การ rollback แบบ byte-for-byte

หากต้องการย้อนกลับไปใช้ tunnel profile เดิมทุกตัวอักษร:

1. รัน `Lazy-Control.cmd uninstall` ขั้นตอนนี้จะถอด logon task, หยุดการทำงาน, และคืนค่า **backup ล่าสุดที่ยังใช้ได้** จาก `%APPDATA%\tunnel-client\backups\` ทับ profile ที่ใช้งานอยู่โดยอัตโนมัติ
2. หากต้องการคืนค่า backup รุ่นเก่ากว่านั้นโดยเฉพาะ ให้คัดลอกไฟล์ `dwb-serena.<timestamp>.yaml` ที่ต้องการจาก `%APPDATA%\tunnel-client\backups\` ไปทับ `%APPDATA%\tunnel-client\dwb-serena.yaml` แบบ byte-for-byte (ห้ามแก้ไขเนื้อไฟล์เอง)
3. รัน `Start.cmd` (หรือ `Lazy-Control.cmd start`) อีกครั้งเพื่อใช้ profile ที่คืนค่าแล้ว

`install` จะไม่ลบ backup เก่าเลย ดังนั้น profile ทุกเวอร์ชันที่เคยถูกแทนที่จะยังอยู่ใน `%APPDATA%\tunnel-client\backups\` สำหรับ rollback เสมอ

## ตรวจ repository ก่อนเผยแพร่

รันชุดตรวจเดียวกับ GitHub Actions ได้ด้วย:

```powershell
.\tests\validate.ps1
```

ชุดตรวจครอบคลุม syntax ของ PowerShell, รูปแบบ Tunnel ID, profile ที่ไม่ฝัง key, `.gitignore` และไฟล์ generated/credential ที่ห้ามถูก track

## ความปลอดภัย

- Serena อาจมีเครื่องมืออ่าน/แก้ไฟล์และรันคำสั่ง shell
- เชื่อมเฉพาะ OpenAI/ChatGPT workspace ที่ไว้ใจ และ activate เฉพาะโปรเจกต์ที่ตั้งใจ
- ตรวจ tool call ก่อนอนุมัติ โดยเฉพาะคำสั่งลบ ย้าย ติดตั้ง หรือเผยแพร่ข้อมูล
- งานที่มีข้อมูลสำคัญควรรัน Serena ภายใน sandbox หรือ container
- DPAPI ป้องกัน key ขณะเก็บบนดิสก์ แต่ระหว่างรัน key จะถูกถอดรหัสใน environment ของ process
- ถ้า key หลุด ให้ revoke/rotate ทันที แล้วรัน `Configure.cmd` ใหม่
- Listener ของ lazy proxy และ tunnel-client ผูกกับ `127.0.0.1` เท่านั้น status endpoint (พอร์ต 18012) ไม่เปิดเผย secret, argument/ผลลัพธ์ของ tool หรือ path โปรเจกต์
- `Lazy-Control.cmd install` ลงทะเบียน logon task แบบ **จำกัดเฉพาะผู้ใช้ปัจจุบันและไม่ยกระดับสิทธิ์** ส่วน `stop`/`uninstall` จะตรวจ executable path และ command line ก่อนส่งสัญญาณหยุดเสมอ ดูรายละเอียดใน [SECURITY.md](SECURITY.md)
- แม้ Serena จะ idle อยู่ แต่ตราบใด tunnel/proxy ยังทำงาน tunnel principal ที่ผ่านการยืนยันตัวตนแล้วสามารถสั่งให้ Serena เริ่มทำงานและเรียก tool จริงได้ทุกเมื่อ ให้ถือว่า "tunnel เชื่อมต่ออยู่" เทียบเท่ากับ "Serena เข้าถึงได้" ในแง่ความน่าเชื่อถือ

## แก้ปัญหาเบื้องต้น

### พบ Serena แต่เปิดไม่ได้

```powershell
serena --version
serena --help
```

ถ้า installation เสีย:

```powershell
uv tool uninstall serena-agent
uv tool install -p 3.13 serena-agent
serena init
```

### Preflight ไม่ผ่าน

อ่านรายละเอียดจาก `doctor --explain` ในหน้าต่าง `Start.cmd` สาเหตุที่พบบ่อยคือ key ไม่มีสิทธิ์, Tunnel ID อยู่ผิด organization/workspace หรือ Serena เปิดไม่ได้

## เอกสารทางการ

- [OpenAI Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels)
- [OpenAI tunnel-client](https://github.com/openai/tunnel-client)
- [Serena installation](https://oraios.github.io/serena/02-usage/010_installation.html)
- [Serena project workflow](https://oraios.github.io/serena/02-usage/040_workflow.html)
- [Serena security considerations](https://oraios.github.io/serena/02-usage/070_security.html)

## License

สคริปต์ใน repository นี้ใช้ MIT License ซอฟต์แวร์ third-party ที่ `Setup.cmd` ดาวน์โหลดมายังคงใช้ license และ notices ของเจ้าของโครงการนั้น
