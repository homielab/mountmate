# 🚀 MountMate

_Một ứng dụng đơn giản trên thanh menu macOS giúp bạn quản lý ổ đĩa ngoài._

---

<img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/assets/icon.png" alt="MountMate Icon" width="100" height="100" style="border-radius: 22%; border: 0.5px solid rgba(0,0,0,0.1);" />

## ⚡️ Bắt đầu nhanh

Cài bằng [Homebrew](https://brew.sh):

```bash
brew install mountmate
```

Hoặc [tải `.dmg` mới nhất](https://github.com/homielab/mountmate/releases) rồi kéo MountMate.app vào thư mục Applications.

## 🖼️ Hình ảnh minh họa

<img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light.png" width="300" /><img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/dark.png" width="300" />

![Toàn bộ giao diện](https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light-full.png)

## ✅ Tính năng nổi bật

- Mount, unmount, mount chỉ đọc và ép eject mọi ổ ngoài chỉ với một cú click trên thanh menu.
- Xem dung lượng trống của ổ và của network share đã mount ngay trong popover.
- Unmount All, Mount All và Eject All External Disks bằng nút hoặc phím tắt toàn cục.
- Tự unmount khi máy ngủ hoặc khi ổ không dùng, và mount lại khi máy thức dậy.
- Chặn ổ USB tự mount khi cắm hoặc khi đăng nhập, tuỳ chọn chặn cả lúc khởi động (`/etc/fstab`).
- Mount phân vùng hoặc network share tại điểm mount bạn chọn.
- Mở khoá ổ APFS mã hoá, có thể lưu mật khẩu vào Keychain.
- Tự mount SMB và NFS khi đăng nhập (share AFP cũ giữ nguyên kèm nhãn không còn hỗ trợ) và để Keep Alive nối lại khi bị rớt.
- Cảnh báo "Almost full" và SMART, cùng thông báo tuỳ chọn.
- Ignore, Protect hoặc Pin phân vùng, hiện Apple RAID thành một ổ, tuỳ chỉnh danh sách trong popover.
- Tự động hoá bằng 10 hành động Shortcuts (cả Spotlight, Siri, Automator).
- 100% native (không Electron), 7 ngôn ngữ, hỗ trợ bàn phím và VoiceOver; phụ thuộc duy nhất là Sparkle để cập nhật.

Xem [FEATURES-vi.md](FEATURES-vi.md) để biết từng mục làm gì.

## 🧩 MountMate là gì?

MountMate là một tiện ích nhẹ dành cho macOS, chạy trên thanh menu và cho phép bạn **mount (gắn) hoặc unmount (tháo) ổ đĩa ngoài chỉ với một cú nhấp chuột** – không cần Terminal, không cần mở Disk Utility, hoàn toàn đơn giản.

Nếu bạn đang sử dụng ổ HDD, muốn kiểm soát khi nào nó hoạt động để tránh gây ồn hoặc làm chậm hệ thống, MountMate là giải pháp gọn nhẹ dành cho bạn.

## 🧠 Tại sao tôi tạo ra ứng dụng này?

Tôi có một ổ cứng ngoài 4TB được cắm thường trực vào Mac mini tại nhà. Vì là ổ HDD, mỗi lần tôi mở Finder, Spotlight hay thực hiện một số thao tác hệ thống, ổ sẽ quay lên – gây tiếng ồn, làm chậm hệ thống và không cần thiết khi tôi không dùng đến.

Các giải pháp:

- Dùng Disk Utility – quá chậm và bất tiện
- Viết script bằng shell – không thân thiện
- Tìm ứng dụng bên thứ ba – phức tạp hoặc không hiệu quả

Vì vậy, tôi đã tạo **MountMate**.


## ✨ MountMate dành cho ai?

macOS sẽ tự động mount ổ đĩa khi bạn cắm vào – nhưng **không cho phép bạn mount lại một cách dễ dàng nếu đã unmount**. MountMate đặc biệt hữu ích nếu bạn:

- Sử dụng ổ ngoài chỉ để sao lưu hoặc lưu trữ tạm thời
- Không muốn ổ cứng quay suốt cả ngày
- Muốn giảm tiếng ồn, tăng hiệu năng hệ thống

## 🔐 An toàn, nhanh, và riêng tư

MountMate hoạt động **hoàn toàn ngoại tuyến**, sử dụng lệnh và API tích hợp sẵn của macOS. Ứng dụng:

- **Không theo dõi** hay gửi dữ liệu
- **Không cần internet**, trừ khi kiểm tra bản cập nhật (Sparkle)
- **Không truy cập dữ liệu cá nhân**
- **Không chạy với quyền root**: chỉ hỏi mật khẩu quản trị khi ghi `/etc/fstab` (điểm mount tuỳ chỉnh của phân vùng, Block at Startup)

Chỉ là một tiện ích nhỏ gọn, làm đúng một việc – và làm tốt.

## 🛠️ Hướng dẫn cài đặt

### Yêu cầu

- macOS 13 Ventura trở lên

### Cài bằng Homebrew

```bash
brew install mountmate
```

### Cài thủ công (dành cho người mới hoặc cập nhật thủ công)

1. [Tải về `.dmg` bản mới nhất](https://github.com/homielab/mountmate/releases)
2. Mở file `.dmg`
3. Kéo biểu tượng `MountMate.app` vào thư mục **Applications**
4. Eject (gỡ) ổ đĩa cài đặt
5. Mở MountMate từ thư mục **Applications**

### Lần đầu sử dụng

- Nếu macOS cảnh báo ứng dụng không rõ nguồn gốc, hãy vào:  
  **System Settings → Privacy & Security → Open Anyway**
- Đảm bảo bạn kết nối mạng để macOS xác minh; các bản cập nhật sau đó do Sparkle tự tải (Settings → About & Updates)
- MountMate chỉ hỏi mật khẩu quản trị để sửa `/etc/fstab` ("Also Block at Startup", điểm mount tuỳ chỉnh); Full Disk Access (System Settings → Privacy & Security) giúp đọc ổ trong thư mục được bảo vệ

## 🔐 Lỗi network share

Khi một share SMB hoặc AFP không mount được, MountMate nêu nguyên nhân và điều cần kiểm tra, kèm mã lỗi gốc (ví dụ `Error code: 80 (EAUTH)`). Hãy gửi kèm dòng này khi báo lỗi.

- **Xác thực thất bại (`EAUTH`)**: sai tên đăng nhập hoặc mật khẩu. Với tài khoản domain Windows, nhập `DOMAIN\user` hoặc `user@domain` (`DOMAIN;user` cũng được).
- **Bị từ chối truy cập (`EACCES`)**: server nhận kết nối nhưng không cho tài khoản này dùng share. Kiểm tra quyền của tài khoản; nếu lỗi bắt đầu sau khi server cập nhật, hỏi quản trị viên xem server còn chấp nhận SMB 2/3 với đăng nhập NTLMv2 không.
- **Mật khẩu hết hạn, chính sách, tài khoản bị hạn chế (`ENETFSPWDNEEDSCHANGE`, `ENETFSPWDPOLICY`, `ENETFSACCOUNTRESTRICTED`)**: phải xử lý tài khoản phía server.
- **Không có cách đăng nhập hoặc phiên bản giao thức được hỗ trợ (`ENETFSNOAUTHMECHSUPP`, `ENETFSNOPROTOVERSSUPP`)**: server phải cho phép NTLMv2/Kerberos và SMB 2 hoặc 3.
- **Không thấy share (`ENOENT`)**, **kết nối bị từ chối (`ECONNREFUSED`)**, **không tới được server (`EHOSTUNREACH`)**: kiểm tra tên share, File Sharing đã bật chưa và mạng.

## 🪵 Gửi log khi báo lỗi

Khi báo lỗi (ví dụ ổ mạng không mount được), log giúp tìm nguyên nhân nhanh hơn. MountMate ghi vào unified log của macOS với subsystem `com.homielab.mountmate`.

Cách dễ nhất: làm lại thao tác bị lỗi, mở **Cài đặt → Chung → Nhật ký** rồi bấm **Sao chép chẩn đoán**, dán kết quả vào issue. Báo cáo gồm phiên bản MountMate và macOS, các cài đặt bật/tắt và nhật ký 1 giờ gần nhất của MountMate; không có mật khẩu, đường dẫn, tên ổ đĩa hay tên thư mục chia sẻ.

Cách dự phòng: chạy trong Terminal và đính kèm file `mountmate.log` vào issue:

```bash
log show --predicate 'subsystem == "com.homielab.mountmate"' --last 1h --info > ~/Desktop/mountmate.log
```

Xem trực tiếp khi mount/unmount: `log stream --predicate 'subsystem == "com.homielab.mountmate"' --level info`, hoặc lọc theo subsystem này trong Console.app. Mật khẩu không bao giờ được ghi; tên share, tên ổ, đường dẫn và chi tiết lỗi hiện là `<private>`.

## 🧑‍💻 Phát triển

Build, test, kiến trúc và phát hành: xem [DEVELOPMENT.md](DEVELOPMENT.md) (tiếng Anh). Quy ước: [CONTRIBUTING.md](CONTRIBUTING.md).

## 📫 Đóng góp & phản hồi

MountMate được tạo để giải quyết nhu cầu cá nhân của tôi – nhưng tôi rất sẵn lòng cải thiện nó cho cộng đồng.
Nếu bạn có góp ý hoặc muốn tham gia phát triển, [hãy mở issue tại đây](https://github.com/homielab/mountmate/issues) (form báo lỗi hỏi mã lỗi và log)! Pull request cũng được chào đón: xem [CONTRIBUTING.md](CONTRIBUTING.md).

## 🤝 Hỗ trợ

Nếu bạn thấy MountMate hữu ích, hãy ủng hộ phát triển:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/homielab)
