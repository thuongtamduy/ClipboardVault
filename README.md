# ClipboardVault (macOS, SwiftUI)

Ứng dụng macOS hiện đại giúp quản lý lịch sử clipboard của bạn một cách an toàn và tiện lợi, hỗ trợ cả `text` và `image`.

## 🚀 Tính năng nổi bật

- **Lưu trữ vĩnh viễn**: Sử dụng SQLite để lưu trữ lịch sử clipboard, không bị mất dữ liệu khi khởi động lại app.
- **Chạy trên Menubar**: Hoạt động nhẹ nhàng dưới dạng ứng dụng thanh menu (Menubar Extra) giúp truy cập nhanh.
- **Giao diện hiện đại**: Hỗ trợ giao diện đẹp mắt với kính mờ (vibrant), hiệu ứng gradient và bo góc hiện đại.
- **Phím tắt toàn cục (Global Hotkey)**: Nhấn `Cmd + Shift + V` để kích hoạt nhanh ứng dụng từ bất kỳ đâu.
- **Phân loại thông minh**: Tự động nhận diện URL và mã màu Hex, hiển thị preview trực quan.
- **Bộ lọc mạnh mẽ**: Lọc theo Tất cả, Văn bản, Hình ảnh và Mục yêu thích.
- **Mục yêu thích (Favorites)**: Ghim các item quan trọng lên đầu danh sách.
- **Khởi động cùng máy**: Tùy chọn tự động chạy khi đăng nhập macOS.
- **Tự động cài đặt**: Hỗ trợ di chuyển ứng dụng vào thư mục `Applications` để hoạt động ổn định nhất.

## 🛠 Cách chạy

### Cách 1: Chạy nhanh bằng lệnh

```bash
swift run
```

### Cách 2: Sử dụng script build

```bash
./build_app.sh
```
Script này sẽ build ra file `ClipboardVault.app` hoàn chỉnh.

### Mở bằng Xcode

```bash
open Package.swift
```

## ⚙️ Chi tiết kỹ thuật

- **Ngôn ngữ**: Swift 5.9+ (SwiftUI)
- **Cơ sở dữ liệu**: SQLite3 (chế độ WAL để tối ưu hiệu năng)
- **Polling**: Kiểm tra clipboard mỗi `0.5s` qua `NSPasteboard.changeCount`.
- **Giới hạn**: Tối đa 200 item (có thể tùy chỉnh trong code).

## 📝 Ghi chú

- Ứng dụng sử dụng Carbon API để đăng ký phím tắt toàn cục `Cmd + Shift + V`.
- Dữ liệu hình ảnh được lưu dưới dạng BLOB trong SQLite.
