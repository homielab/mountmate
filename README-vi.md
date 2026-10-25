# 🚀 MountMate

_Một ứng dụng đơn giản trên thanh menu macOS giúp bạn quản lý ổ đĩa ngoài._

---

<img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/assets/icon.png" alt="MountMate Icon" width="100" height="100" style="border-radius: 22%; border: 0.5px solid rgba(0,0,0,0.1);" />

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

## ✅ Tính năng nổi bật

- Xem tất cả ổ đĩa ngoài đang kết nối
- Biết được ổ nào đang được **mount**
- **Mount/unmount** nhanh chóng chỉ với 1 cú click
- Hiển thị **dung lượng trống** còn lại
- **Tự ngắt khi không dùng**: chọn cho từng phân vùng trên ổ ngoài (chuột phải → Tự ngắt khi không dùng) để tự unmount sau 1–60 phút ổ không đọc/ghi; không bao giờ ép buộc, phân vùng đang dùng sẽ được giữ nguyên và thử lại sau
- Chạy gọn nhẹ trên **thanh menu**
- 100% native – không dùng Electron, không phụ thuộc nặng nề

## ✨ MountMate dành cho ai?

macOS sẽ tự động mount ổ đĩa khi bạn cắm vào – nhưng **không cho phép bạn mount lại một cách dễ dàng nếu đã unmount**. MountMate đặc biệt hữu ích nếu bạn:

- Sử dụng ổ ngoài chỉ để sao lưu hoặc lưu trữ tạm thời
- Không muốn ổ cứng quay suốt cả ngày
- Muốn giảm tiếng ồn, tăng hiệu năng hệ thống

## 🔐 An toàn, nhanh, và riêng tư

MountMate hoạt động **hoàn toàn ngoại tuyến**, sử dụng lệnh và API tích hợp sẵn của macOS. Ứng dụng:

- **Không theo dõi** hay gửi dữ liệu
- **Không yêu cầu kết nối mạng**
- **Không truy cập dữ liệu cá nhân**
- **Không cần quyền root**

Chỉ là một tiện ích nhỏ gọn, làm đúng một việc – và làm tốt.

## 🖼️ Hình ảnh minh họa

<img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light.png" width="300" /><img src="https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/dark.png" width="300" />

![Toàn bộ giao diện](https://raw.githubusercontent.com/homielab/mountmate/main/docs/screenshots/light-full.png)

## 🛠️ Hướng dẫn cài đặt

### Cài thủ công (dành cho người mới hoặc cập nhật thủ công)

1. [Tải về `.dmg` bản mới nhất](https://github.com/homielab/mountmate/releases)
2. Mở file `.dmg`
3. Kéo biểu tượng `MountMate.app` vào thư mục **Applications**
4. Eject (gỡ) ổ đĩa cài đặt
5. Mở MountMate từ thư mục **Applications**

### Lần đầu sử dụng

- Nếu macOS cảnh báo ứng dụng không rõ nguồn gốc, hãy vào:  
  **System Settings → Privacy & Security → Open Anyway**
- Đảm bảo bạn kết nối mạng để macOS xác minh và tự động cập nhật

## 🪵 Gửi log khi báo lỗi

Khi báo lỗi (ví dụ ổ mạng không mount được), log giúp tìm nguyên nhân nhanh hơn. MountMate ghi vào unified log của macOS với subsystem `com.homielab.mountmate`.

Làm lại thao tác bị lỗi, rồi chạy trong Terminal và đính kèm file `mountmate.log` vào issue:

```bash
log show --predicate 'subsystem == "com.homielab.mountmate"' --last 1h --info > ~/Desktop/mountmate.log
```

Xem trực tiếp khi mount/unmount: `log stream --predicate 'subsystem == "com.homielab.mountmate"' --level info`, hoặc lọc theo subsystem này trong Console.app. Mật khẩu không bao giờ được ghi; tên share, tên ổ, đường dẫn và chi tiết lỗi hiện là `<private>`.

## 📫 Đóng góp & phản hồi

MountMate được tạo để giải quyết nhu cầu cá nhân của tôi – nhưng tôi rất sẵn lòng cải thiện nó cho cộng đồng.
Nếu bạn có góp ý hoặc muốn tham gia phát triển, [hãy mở issue tại đây](https://github.com/homielab/mountmate/issues)!

## 🤝 Hỗ trợ

Nếu bạn thấy MountMate hữu ích, hãy ủng hộ phát triển:

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/homielab)
