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
