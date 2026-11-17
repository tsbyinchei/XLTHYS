%% ========================================================================
% MAIN_OFFLINE_ANALYSIS.M
% ĐỒ ÁN MÔN HỌC: XỬ LÝ TÍN HIỆU Y SINH (BDSP) - ĐẠI HỌC PHENIKAA
% Đề tài: Xây dựng hệ thống thu nhận và xử lý tín hiệu âm thanh hô hấp 
%         thời gian thực sử dụng ESP32 và MATLAB nhằm nhận diện chu kỳ thở 
%         và ước lượng nhịp thở.
%
% Sinh viên thực hiện : Nguyễn Văn Tuấn Sỹ
% Mã số sinh viên     : 24100986
% Lớp                 : K18-KTYS
% ========================================================================
clear; clc; close all;

fprintf('====================================================================\n');
fprintf('  HỆ THỐNG XỬ LÝ TÍN HIỆU ÂM THANH HÔ HẤP (ESP32 - MATLAB)\n');
fprintf('  Sinh viên : Nguyễn Văn Tuấn Sỹ  |  MSSV: 24100986\n');
fprintf('====================================================================\n\n');

%% BƯỚC 1: TẢI BẢN GHI TÍN HIỆU ÂM THANH HÔ HẤP (TUẦN 2)
curr_dir = fileparts(mfilename('fullpath'));
project_dir = fileparts(curr_dir);
data_dir = fullfile(project_dir, 'data');
docs_dir = fullfile(project_dir, 'docs');
if ~exist(docs_dir, 'dir'), mkdir(docs_dir); end

mat_files = dir(fullfile(data_dir, '*.mat'));
if isempty(mat_files)
    fprintf('--> Đang khởi tạo dữ liệu mẫu y sinh chuẩn...\n');
    generate_sample_data(60.0, 14.0);
    mat_files = dir(fullfile(data_dir, '*.mat'));
end

[~, latest_idx] = max([mat_files.datenum]);
data_path = fullfile(data_dir, mat_files(latest_idx).name);
fprintf('--> Đang nạp dữ liệu từ: %s\n', mat_files(latest_idx).name);

loaded_data = load(data_path);
if isfield(loaded_data, 'raw_signal')
    x = double(loaded_data.raw_signal(:));
elseif isfield(loaded_data, 'data')
    x = double(loaded_data.data(:));
else
    error('File .mat không chứa biến tín hiệu hợp lệ!');
end

if isfield(loaded_data, 'Fs')
    Fs = double(loaded_data.Fs);
else
    Fs = 4000;
end

if isfield(loaded_data, 'ground_truth_bpm')
    ground_truth_bpm = double(loaded_data.ground_truth_bpm);
else
    ground_truth_bpm = 14.0;
end

N = length(x);
t = (0:N-1)' / Fs;
fprintf('    Thời lượng bản ghi: %.2f giây (%d mẫu) | Fs = %d Hz\n\n', t(end), N, Fs);

%% BƯỚC 2: THIẾT KẾ BỘ LỌC SỐ: NOTCH 50 HZ & IIR BANDPASS (TUẦN 5 & 6)
% 2.1. Bộ lọc Notch 50 Hz triệt nhiễu điện lưới (Tuần 6)
w0 = 2 * pi * 50 / Fs;
r = 1 - (pi * 2 / Fs);
b_notch = [1, -2*cos(w0), 1] * ((1 - 2*r*cos(w0) + r^2) / (2 - 2*cos(w0)));
a_notch = [1, -2*r*cos(w0), r^2];

% 2.2. Bộ lọc dải thông IIR Butterworth bậc 4 (100 - 1000 Hz) chọn lọc âm phế quản (Tuần 5)
f_nyq = Fs / 2;
[b_bp, a_bp] = butter(4, [100, 1000] / f_nyq, 'bandpass');

% Lọc 2 chiều zero-phase triệt tiêu độ trễ pha
y_notch = filtfilt(b_notch, a_notch, x);
y_clean = filtfilt(b_bp, a_bp, y_notch);

fprintf('--> Hoàn thành lọc số: Triệt nhiễu điện lưới 50 Hz & Lọc dải 100 - 1000 Hz.\n');

%% BƯỚC 3: PHÂN TÍCH PHỔ FOURIER (FFT) TRƯỚC VÀ SAU LỌC (TUẦN 4 & 5)
N_fft = 2^nextpow2(min(N, 65536));
f_axis = (0:(N_fft/2)) * (Fs / N_fft);

X_raw  = abs(fft(x(1:N_fft) - mean(x(1:N_fft)), N_fft)) / N_fft;
X_filt = abs(fft(y_clean(1:N_fft), N_fft)) / N_fft;

P_raw  = X_raw(1:N_fft/2 + 1);
P_filt = X_filt(1:N_fft/2 + 1);

%% BƯỚC 4: THUẬT TOÁN TÍCH PHÂN CỬA SỔ TRƯỢT PAN-TOMPKINS (TUẦN 7)
% 4.1. Đạo hàm bậc 1 (5 điểm)
h_diff = [1/4, 1/8, 0, -1/8, -1/4] * Fs;
y_diff = filter(h_diff, 1, y_clean);

% 4.2. Bình phương biên độ khuếch đại năng lượng
y_sq = y_diff .^ 2;

% 4.3. Tích phân cửa sổ trượt (Moving Window Integration - MWI 250 ms)
W = round(0.25 * Fs); 
h_mwi = ones(W, 1) / W;
y_mwi_raw = filter(h_mwi, 1, y_sq);

% Làm mịn đường bao năng lượng (Low-pass filter nhẹ 2.5 Hz) loại bỏ gợn răng cưa vi mô
[b_sm, a_sm] = butter(2, 2.5 / f_nyq, 'low');
y_mwi = filtfilt(b_sm, a_sm, y_mwi_raw);
y_mwi(y_mwi < 0) = 0;

% Chuẩn hóa đường bao MWI về thang [0, 1]
y_mwi_norm = y_mwi / max(y_mwi);

fprintf('--> Trích xuất đường bao năng lượng MWI trơn tru (Cửa sổ W = %d mẫu).\n', W);

%% BƯỚC 5: NGƯỠNG THÍCH NGHI VÀ NHẬN DIỆN ĐỈNH CHU KỲ THỞ (TUẦN 8)
% Dò tìm các đỉnh cực đại thực thụ (Apex Summits) với khoảng cách tối thiểu giữa 2 đỉnh là 1.0 giây
min_peak_dist = round(1.0 * Fs);
[raw_pks, raw_locs] = findpeaks(y_mwi_norm, 'MinPeakDistance', min_peak_dist, 'MinPeakProminence', 0.12);

% Thuật toán Ngưỡng thích ứng kép Pan-Tompkins cập nhật hồi quy
SP = 0.65;
NP = 0.10;
alpha = 0.25;

peak_indices = [];
th_track = zeros(N, 1);

% Tạo đường ngưỡng thích ứng bám theo thời gian
current_th = NP + alpha * (SP - NP);
loc_idx = 1;
for n = 1:N
    if loc_idx <= length(raw_locs) && n == raw_locs(loc_idx)
        pk_val = raw_pks(loc_idx);
        if pk_val >= current_th
            peak_indices = [peak_indices; n];
            SP = 0.125 * pk_val + 0.875 * SP; % Cập nhật mức tín hiệu SP
        else
            NP = 0.125 * pk_val + 0.875 * NP; % Cập nhật mức nhiễu NP
        end
        current_th = min(0.80, max(0.18, NP + alpha * (SP - NP)));
        loc_idx = loc_idx + 1;
    end
    th_track(n) = current_th;
end

fprintf('--> Nhận diện thành công %d đỉnh thì thở tại đúng cực đại đỉnh núi.\n', length(peak_indices));

%% BƯỚC 6: TÍNH TỐC ĐỘ HÔ HẤP (BPM) VÀ ĐÁNH GIÁ SAI SỐ
peak_times = t(peak_indices);

if length(peak_times) >= 2
    diffs = diff(peak_times);
    median_diff = median(diffs);
    
    if median_diff >= 2.5
        cycle_durations = diffs;
    else
        cycle_durations = peak_times(3:end) - peak_times(1:end-2);
    end
    
    bpm_inst = 60 ./ cycle_durations;
    valid_bpm = bpm_inst(bpm_inst >= 8 & bpm_inst <= 35);
    if isempty(valid_bpm)
        estimated_bpm = mean(bpm_inst);
    else
        estimated_bpm = mean(valid_bpm);
    end
else
    estimated_bpm = 0;
    bpm_inst = [];
    cycle_durations = [];
end

err_abs = abs(estimated_bpm - ground_truth_bpm);
err_rel = (err_abs / ground_truth_bpm) * 100;
accuracy = 100 - err_rel;

fprintf('\n====================================================================\n');
fprintf('  KẾT QUẢ ĐÁNH GIÁ ĐỘ CHÍNH XÁC ƯỚC LƯỢNG NHỊP THỞ\n');
fprintf('====================================================================\n');
fprintf('  - Nhịp thở ước tính từ thuật toán : %.2f lần/phút (BPM)\n', estimated_bpm);
fprintf('  - Nhịp thở đếm thủ công chuẩn     : %.2f lần/phút (BPM)\n', ground_truth_bpm);
fprintf('  - Sai số tuyệt đối                : %.2f BPM\n', err_abs);
fprintf('  - Sai số tương đối                : %.2f %%\n', err_rel);
fprintf('  - Độ chính xác đạt được           : %.2f %%\n', accuracy);
fprintf('====================================================================\n\n');

%% BƯỚC 7: XUẤT ĐỒ THỊ CHUẨN ĐỘ PHÂN GIẢI CAO PHỤC VỤ BÁO CÁO

% --- HÌNH 1: TÍN HIỆU THỜI GIAN VÀ PHÂN TÍCH PHỔ FFT TRƯỚC / SAU LỌC ---
f1 = figure('Name', 'Hinh 1: Tin hieu va Pho FFT', 'Color', 'w', 'Position', [100, 80, 1050, 700]);

subplot(2, 2, 1);
plot(t, x, 'Color', [0.35, 0.35, 0.35], 'LineWidth', 0.8);
title('(a) Dạng sóng âm thở thô từ ESP32-C3', 'FontWeight', 'bold', 'FontSize', 10.5);
xlabel('Thời gian (giây)'); ylabel('Biên độ ADC (Raw)');
grid on; xlim([0, min(15, t(end))]); ylim([-3500, 3500]);

subplot(2, 2, 2);
plot(t, y_clean, 'Color', [0.0, 0.45, 0.85], 'LineWidth', 0.9);
title('(b) Dạng sóng sau lọc Notch 50Hz + Bandpass (100 - 1000 Hz)', 'FontWeight', 'bold', 'FontSize', 10.5);
xlabel('Thời gian (giây)'); ylabel('Biên độ tín hiệu sạch');
grid on; xlim([0, min(15, t(end))]); ylim([-3500, 3500]);

subplot(2, 2, 3);
plot(f_axis, P_raw, 'Color', [0.85, 0.33, 0.1], 'LineWidth', 1.0);
title('(c) Phổ FFT trước lọc (Nhiễu 50 Hz & trôi dạt cơ học)', 'FontWeight', 'bold', 'FontSize', 10.5);
xlabel('Tần số (Hz)'); ylabel('Biên độ phổ');
grid on; xlim([0, 1500]); ylim([0, max(P_raw) * 1.25]);

subplot(2, 2, 4);
plot(f_axis, P_filt, 'Color', [0.1, 0.65, 0.3], 'LineWidth', 1.0);
title('(d) Phổ FFT sau lọc (Tập trung dải phế quản 100 - 1000 Hz)', 'FontWeight', 'bold', 'FontSize', 10.5);
xlabel('Tần số (Hz)'); ylabel('Biên độ phổ');
grid on; xlim([0, 1500]); ylim([0, max(P_filt) * 1.25]);

saveas(f1, fullfile(docs_dir, 'hinh1_tin_hieu_va_pho_fft.png'));
fprintf('--> Đã lưu đồ thị chuẩn: %s\n', fullfile(docs_dir, 'hinh1_tin_hieu_va_pho_fft.png'));

% --- HÌNH 2: CÁC BƯỚC PAN-TOMPKINS VÀ NHẬN DIỆN ĐỈNH NHỊP THỞ ---
f2 = figure('Name', 'Hinh 2: Pan-Tompkins va Nhan dien dinh', 'Color', 'w', 'Position', [150, 60, 1100, 780]);

subplot(3, 1, 1);
plot(t, y_clean, 'Color', [0.0, 0.45, 0.85], 'LineWidth', 0.9);
title('(a) Tín hiệu âm thanh hô hấp sạch sau lọc số', 'FontWeight', 'bold', 'FontSize', 10.5);
xlabel('Thời gian (giây)'); ylabel('Biên độ'); grid on;
xlim([0, min(20, t(end))]); ylim([-3500, 3500]);

subplot(3, 1, 2); hold on;
plot(t, y_mwi_norm, 'Color', [0.15, 0.70, 0.25], 'LineWidth', 1.3, 'DisplayName', 'Đường bao MWI (250ms)');
plot(t, th_track, '--r', 'LineWidth', 1.2, 'DisplayName', 'Ngưỡng thích ứng kép');
p_sel = peak_indices(peak_times <= 20);
plot(t(p_sel), y_mwi_norm(p_sel), 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 7, 'DisplayName', 'Đỉnh thì thở (Apex)');
title('(b) Trích xuất đường bao MWI, Ngưỡng thích ứng và Phát hiện đỉnh chính xác', 'FontWeight', 'bold', 'FontSize', 10.5);
xlabel('Thời gian (giây)'); ylabel('Biên độ chuẩn hóa'); grid on;
legend('Location', 'northeast', 'FontSize', 9);
xlim([0, min(20, t(end))]); ylim([0, 1.25]);

subplot(3, 1, 3);
if ~isempty(bpm_inst)
    if length(bpm_inst) == length(peak_times) - 1
        t_bpm = peak_times(2:end);
    else
        t_bpm = peak_times(3:end);
    end
    hold on;
    h_inst = plot(t_bpm, bpm_inst, 's-', 'Color', [0.85, 0.33, 0.1], 'LineWidth', 1.3, ...
                  'MarkerFaceColor', [0.85, 0.33, 0.1], 'MarkerSize', 6);
    h_est  = yline(estimated_bpm, '-b', 'LineWidth', 1.6);
    h_tru  = yline(ground_truth_bpm, '--k', 'LineWidth', 1.4);
    
    title('(c) Tốc độ hô hấp tức thời (BPM) qua từng chu kỳ thở', 'FontWeight', 'bold', 'FontSize', 10.5);
    xlabel('Thời gian (giây)'); ylabel('Nhịp thở (lần/phút)'); grid on;
    xlim([0, min(20, t(end))]); ylim([5, 30]);
    
    % Chú thích rõ ràng trong hộp Legend, không để đè chữ lên nhau
    legend([h_inst, h_est, h_tru], ...
           {'BPM tức thời từng nhịp', ...
            sprintf('Ước lượng trung bình: %.1f BPM', estimated_bpm), ...
            sprintf('Chuẩn Ground Truth: %.1f BPM', ground_truth_bpm)}, ...
           'Location', 'northeast', 'FontSize', 9);
end

saveas(f2, fullfile(docs_dir, 'hinh2_pan_tompkins_va_nhan_dien_dinh.png'));
fprintf('--> Đã lưu đồ thị chuẩn: %s\n', fullfile(docs_dir, 'hinh2_pan_tompkins_va_nhan_dien_dinh.png'));
fprintf('\n--> HOÀN THÀNH TIẾN TRÌNH XUẤT ĐỒ THỊ CHUẨN!\n');
