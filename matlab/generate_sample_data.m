%% ========================================================================
% GENERATE_SAMPLE_DATA.M
% Hàm tạo dữ liệu âm thanh hô hấp mô phỏng chuẩn y sinh (Fs = 4000 Hz)
% Đề tài: Hệ thống thu nhận và xử lý tín hiệu âm thanh hô hấp (ESP32 & MATLAB)
% Sinh viên: Nguyễn Văn Tuấn Sỹ - MSSV: 24100986
% ========================================================================
function [raw_signal, t, Fs, ground_truth_bpm] = generate_sample_data(duration_sec, target_bpm)
    if nargin < 1, duration_sec = 60.0; end
    if nargin < 2, target_bpm = 14.0; end

    Fs = 4000;
    N = round(duration_sec * Fs);
    t = (0:N-1)' / Fs;

    ground_truth_bpm = target_bpm;
    avg_cycle = 60.0 / target_bpm; % ~4.28 giây/chu kỳ với 14 BPM

    rng(100); % Đảm bảo tính tái lập

    % Tạo các chu kỳ thở nối tiếp với biến thiên tự nhiên (Physiological Variability ~5%)
    envelope = zeros(N, 1);
    t_start = 0;
    
    while t_start < duration_sec
        % Biến thiên nhẹ chu kỳ thở (4.0 - 4.5s)
        cycle_len = avg_cycle * (0.95 + 0.10 * rand());
        % Biến thiên nhẹ độ sâu nhịp thở (0.85 - 1.15)
        depth = 0.90 + 0.20 * rand();
        
        t_inhale = 0.38 * cycle_len; % ~1.6s
        t_pause1 = 0.46 * cycle_len; % Nghỉ ngắn ~0.3s
        t_exhale = 0.88 * cycle_len; % ~1.8s
        
        idx_cycle = find(t >= t_start & t < (t_start + cycle_len));
        if isempty(idx_cycle), break; end
        
        t_rel = t(idx_cycle) - t_start;
        for k = 1:length(idx_cycle)
            tau = t_rel(k);
            if tau < t_inhale
                % Thì hít vào: Đường cong mượt bậc 2
                envelope(idx_cycle(k)) = depth * (sin(pi * tau / t_inhale) ^ 2);
            elseif tau >= t_pause1 && tau < t_exhale
                % Thì thở ra: Cường độ nhẹ hơn (~80%)
                tau_ex = tau - t_pause1;
                dur_ex = t_exhale - t_pause1;
                envelope(idx_cycle(k)) = 0.82 * depth * (sin(pi * tau_ex / dur_ex) ^ 2);
            else
                % Khoảng nghỉ giữa hai thì thở
                envelope(idx_cycle(k)) = 0.015;
            end
        end
        t_start = t_start + cycle_len;
    end

    % 2. Tạo âm thanh tiếng khí phế quản (Nhiễu dải phế quản 150 - 850 Hz)
    noise_source = randn(N, 1);
    [b_sound, a_sound] = butter(4, [150, 850] / (Fs / 2), 'bandpass');
    breath_core = filter(b_sound, a_sound, noise_source);
    breath_sound = breath_core .* envelope * 2200;

    % 3. Thêm các thành phần tạp âm thực tế:
    % - Nhiễu điện lưới cảm ứng 50 Hz
    hum_50hz = 120 * sin(2 * pi * 50 * t);
    % - Nhiễu trôi đường đẳng điện cơ học do lồng ngực dịch chuyển (0.3 - 1.5 Hz)
    drift = 180 * sin(2 * pi * 0.4 * t) + 120 * cos(2 * pi * 1.2 * t);
    % - Nhiễu nền nhiệt vi cơ MEMS
    ambient = 25 * randn(N, 1);

    % Tín hiệu thô tổng hợp (Raw ADC 16-bit)
    raw_signal = round(breath_sound + hum_50hz + drift + ambient);

    % Tự động lưu vào thư mục data
    curr_dir = fileparts(mfilename('fullpath'));
    project_dir = fileparts(curr_dir);
    data_dir = fullfile(project_dir, 'data');
    if ~exist(data_dir, 'dir'), mkdir(data_dir); end

    save_path = fullfile(data_dir, 'breath_sample_record.mat');
    save(save_path, 'raw_signal', 't', 'Fs', 'ground_truth_bpm');
    fprintf('--> Đã tạo bản ghi âm thở sinh lý chuẩn: %s (%.1f s, %.1f BPM)\n', save_path, duration_sec, target_bpm);
end
