# HỆ THỐNG THU NHẬN VÀ XỬ LÝ ÂM THANH HÔ HẤP THỜI GIAN THỰC (ESP32-C3 & MATLAB)

* **Sinh viên thực hiện :** Nguyễn Văn Tuấn Sỹ
* **Mã số sinh viên     :** 24100986
* **Học phần            :** Xử lý tín hiệu và mô hình hóa y sinh (BDSP)
* **Giảng viên hướng dẫn:** GS. TS. Trần Đức Tân - Trường Đại học Phenikaa

---

## 1. YÊU CẦU MÔI TRƯỜNG & CÀI ĐẶT
1. **Arduino IDE 2.x:**
   * Cài đặt gói bo mạch **ESP32 by Espressif Systems** trong Boards Manager.
   * Chọn bo mạch: **ESP32C3 Dev Module**.
   * Cấu hình nạp:
     * **USB CDC On Boot:** `Enabled` (bắt buộc để truyền tín hiệu I2S qua cổng Type-C).
     * **Flash Frequency:** `80MHz`.
     * **Upload Speed:** `921600`.
2. **MATLAB (Khuyên dùng R2022b trở lên):**
   * Yêu cầu cài đặt **Signal Processing Toolbox** để thực thi các hàm xử lý số tín hiệu (`butter`, `filtfilt`, `findpeaks`, `periodogram`).

---

## 2. SƠ ĐỒ ĐẤU NỐI PHẦN CỨNG (6 DÂY)
Kết nối giữa Module Micro MEMS số hóa **INMP441** và bo mạch **ESP32-C3 SuperMini**:

| Chân INMP441 | Chân ESP32-C3 | Chức năng kỹ thuật & Giao thức |
| :---: | :---: | :--- |
| **VDD** | **3V3** | Cấp nguồn 3.3V từ ổn áp trên bo mạch |
| **GND** | **GND** | Nối đất chuẩn chung toàn hệ thống |
| **L/R** | **GND** | Chọn kênh Mono (Kênh Trái - Left Channel) |
| **SD** | **GPIO 2** | Bus I2S: Truyền chuỗi nhị phân âm thanh số 24-bit (Serial Data) |
| **WS** | **GPIO 3** | Bus I2S: Xung định khung lấy mẫu âm thanh (Word Select) |
| **SCK** | **GPIO 1** | Bus I2S: Xung nhịp đồng hồ bit âm học (Serial Clock) |

> **Lưu ý cơ khí:** Buồng ghép cao su giữa màng rung ống nghe TANAKO và micro INMP441 cần được bọc kín hoàn toàn bằng ống co nhiệt hoặc keo cách âm để triệt tiêu tạp âm phòng.

---

## 3. HƯỚNG DẪN CHẠY CHẾ ĐỘ OFFLINE (KHÔNG CẦN PHẦN CỨNG)
*Phục vụ việc chấm thi hoặc kiểm tra thuật toán nhanh chóng khi không có mạch phần cứng:*
1. Khởi động MATLAB, chuyển thư mục làm việc (*Current Folder*) vào thư mục `matlab/`.
2. Mở file `main_offline_analysis.m` và bấm **Run (F5)**.
3. Phần mềm tự động nạp dữ liệu bản ghi thực tế chuẩn y sinh và hiển thị:
   * **Bảng định lượng y sinh** in ra Command Window: Nhịp thở ước tính (BPM), Ground Truth, Sai số tuyệt đối (MAE = 1.08 BPM), Độ chính xác (93.91%).
   * **Đồ thị phân tích:** Phổ tần số FFT trước/sau lọc Notch 50 Hz & Bandpass 100-1000 Hz, cùng đường bao tích phân năng lượng Pan-Tompkins với các đỉnh hô hấp được nhận diện chính xác.

---

## 4. HƯỚNG DẪN CHẠY CHẾ ĐỘ REAL-TIME (CÓ PHẦN CỨNG)
1. **Nạp Firmware:** Mở file `firmware/esp32_inmp441_i2s/esp32_inmp441_i2s.ino` trên Arduino IDE, cắm cáp USB Type-C vào ESP32-C3 và nhấn **Upload**.
2. **Kiểm tra cổng COM:** Mở *Device Manager* trên Windows để xác định cổng kết nối (mặc định: `COM4`). Nếu máy nhận cổng khác, mở file `matlab/realtime_monitor.m`, đổi dòng `port_name = "COM4";` thành đúng cổng nhận.
3. **Khởi chạy Dashboard:** Trên MATLAB, chạy file `realtime_monitor.m`. Trên thanh công cụ:
   * Nút **Trong phòng (150)**: Dùng khi đo trong phòng yên tĩnh.
   * Nút **Ngoài trời (450)**: Kích hoạt Cổng tiếp xúc âm học chống nhiễu gió/quạt.
4. **Thực hiện đo:** Nhấn **▶ BẮT ĐẦU REAL-TIME**, áp mặt chuông ống nghe TANAKO vào hõm ức khí quản và thở đều. Giao diện hiển thị trực tiếp 4 kênh sóng quét mượt 25 FPS và ước lượng nhịp thở tức thời.
5. *Cơ chế Fallback:* Nếu chưa cắm mạch phần cứng, phần mềm sẽ tự động chuyển sang chế độ Giả lập thời gian thực (Simulation Live) mượt mà không gây gián đoạn.
