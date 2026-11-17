/**
 * ============================================================================
 * ĐỒ ÁN XỬ LÝ TÍN HIỆU Y SINH: HỆ THỐNG THU THẬP ÂM THANH HÔ HẤP THỜI GIAN THỰC
 * ============================================================================
 * Thiết bị: ESP32-C3 SuperMini + Module Micro MEMS I2S INMP441 + Ống nghe y tế
 * Sinh viên thực hiện: Nguyễn Văn Tuấn Sỹ - MSSV: 24100986
 *  *
 * SƠ ĐỒ NỐI CHÂN:
 *   - INMP441 VDD ---> ESP32-C3 3V3
 *   - INMP441 GND ---> ESP32-C3 GND
 *   - INMP441 L/R ---> ESP32-C3 GND (Kênh Mono Left)
 *   - INMP441 SD  ---> ESP32-C3 GPIO 2
 *   - INMP441 WS  ---> ESP32-C3 GPIO 3
 *   - INMP441 SCK ---> ESP32-C3 GPIO 1
 * ============================================================================
 */

#include <Arduino.h>
#include <driver/gpio.h>
#include <driver/i2s.h>

// --- CẤU HÌNH CHÂN I2S CHO ESP32-C3 ---
#define I2S_SCK_PIN 1 // GPIO 1: BCLK (Bit Clock)
#define I2S_WS_PIN 3  // GPIO 3: LRCLK / WS (Word Select)
#define I2S_SD_PIN 2  // GPIO 2: DIN / SD (Serial Data)
#define I2S_PORT I2S_NUM_0

#define BUILTIN_LED_PIN 8 // LED trên bo ESP32-C3 SuperMini (Active LOW)

// Tần số phần cứng I2S: 16.000 Hz (đảm bảo SCK = 1.024 MHz cho INMP441 hoạt
// động ổn định)
#define HW_SAMPLE_RATE 16000
#define DECIMATION_FACTOR 4 // 16000 / 4 = 4000 Hz chuẩn cho MATLAB
#define DMA_BUF_COUNT 4
#define DMA_BUF_LEN 256

#define SERIAL_BAUD_RATE 115200

// Buffer chứa dữ liệu 32-bit từ DMA
static int32_t i2s_raw_buffer[DMA_BUF_LEN * 2];

// Biến khử DC Offset
static float dc_offset = 0.0f;
static int consecutive_zeros = 0;
static bool sensor_ok = false;

void setup_i2s() {
  i2s_config_t i2s_config = {
      .mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX),
      .sample_rate = HW_SAMPLE_RATE,
      .bits_per_sample = I2S_BITS_PER_SAMPLE_32BIT,
      .channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT, // Đọc Stereo khung 32-bit
      .communication_format = i2s_comm_format_t(I2S_COMM_FORMAT_STAND_I2S),
      .intr_alloc_flags = ESP_INTR_FLAG_LEVEL1,
      .dma_buf_count = DMA_BUF_COUNT,
      .dma_buf_len = DMA_BUF_LEN,
      .use_apll = false,
      .tx_desc_auto_clear = false,
      .fixed_mclk = 0};

  i2s_pin_config_t pin_config = {.bck_io_num = I2S_SCK_PIN,
                                 .ws_io_num = I2S_WS_PIN,
                                 .data_out_num = I2S_PIN_NO_CHANGE,
                                 .data_in_num = I2S_SD_PIN};

  // Bật trở kéo xuống chống tĩnh điện chân Data
  gpio_set_pull_mode((gpio_num_t)I2S_SD_PIN, GPIO_PULLDOWN_ONLY);

  i2s_driver_install(I2S_PORT, &i2s_config, 0, NULL);
  i2s_set_pin(I2S_PORT, &pin_config);
  i2s_zero_dma_buffer(I2S_PORT);
}

void setup() {
  Serial.begin(SERIAL_BAUD_RATE);

  // Đợi kết nối USB CDC
  unsigned long waitStart = millis();
  while (!Serial && (millis() - waitStart < 2000)) {
    delay(10);
  }

  pinMode(BUILTIN_LED_PIN, OUTPUT);
  digitalWrite(BUILTIN_LED_PIN, HIGH); // Tắt LED ban đầu

  setup_i2s();
  delay(200); // Đợi micro khởi động xung nhịp
}

void loop() {
  size_t bytes_read = 0;

  esp_err_t result =
      i2s_read(I2S_PORT, (void *)i2s_raw_buffer, sizeof(i2s_raw_buffer),
               &bytes_read, portMAX_DELAY);

  if (result == ESP_OK && bytes_read > 0) {
    int stereo_samples = bytes_read / (sizeof(int32_t) * 2);

    int32_t accum = 0;
    int accum_count = 0;

    for (int i = 0; i < stereo_samples; i++) {
      // Lấy mẫu kênh Left (vì chân L/R của INMP441 đã nối GND)
      int32_t left_raw = i2s_raw_buffer[2 * i];

      // Dịch 16 bit MSB chuẩn có dấu
      int16_t sample_16 = (int16_t)(left_raw >> 16);

      // Kiểm tra trạng thái cảm biến
      if (sample_16 == 0) {
        consecutive_zeros++;
      } else {
        consecutive_zeros = 0;
        sensor_ok = true;
      }

      // Tích lũy để Decimate chia 4 (16000 Hz -> 4000 Hz)
      accum += sample_16;
      accum_count++;

      if (accum_count >= DECIMATION_FACTOR) {
        float avg_sample = (float)accum / DECIMATION_FACTOR;

        // Bộ lọc khử DC Offset (High-pass 1-pole f_c ~ 1 Hz)
        // Giữ cho tín hiệu luôn dao động quanh mức 0 hoàn hảo
        dc_offset = 0.995f * dc_offset + 0.005f * avg_sample;
        int16_t clean_sample = (int16_t)(avg_sample - dc_offset);

        if (consecutive_zeros > 2000) {
          sensor_ok = false;
        }

        if (sensor_ok) {
          digitalWrite(BUILTIN_LED_PIN, LOW); // Sáng LED báo OK
          Serial.println(clean_sample);
        } else {
          // Mất cảm biến: Nháy LED báo động
          digitalWrite(BUILTIN_LED_PIN,
                       ((millis() / 150) % 2 == 0) ? LOW : HIGH);
        }

        accum = 0;
        accum_count = 0;
      }
    }
  }
}
