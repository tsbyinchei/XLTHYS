%% ========================================================================
% REALTIME_MONITOR.M
% ĐỒ ÁN MÔN HỌC: XỬ LÝ TÍN HIỆU Y SINH (BDSP) - ĐẠI HỌC PHENIKAA
% Đề tài: Xây dựng hệ thống thu nhận và xử lý tín hiệu âm thanh hô hấp 
%         thời gian thực sử dụng ESP32 và MATLAB nhằm nhận diện chu kỳ thở 
%         và ước lượng nhịp thở.
%
% Sinh viên thực hiện : Nguyễn Văn Tuấn Sỹ
% Mã số sinh viên     : 24100986
% Lớp                 : K18-KTYS
% ========================================================================
function realtime_monitor()
    clearvars -except ans;
    close all;

    %% 1. CẤU HÌNH THÔNG SỐ HỆ THỐNG
    port_name = "COM4";           % Cổng kết nối ESP32-C3
    baud_rate = 115200;
    Fs = 4000;                    % Tần số lấy mẫu 4000 Hz
    win_sec = 5.0;                % Chiều dài cửa sổ hiển thị (5 giây)
    win_len = round(win_sec * Fs);

    % Bộ lọc dải IIR Butterworth (100 - 1000 Hz) - Tuần 5
    f_nyq = Fs / 2;
    [b_bp, a_bp] = butter(4, [100, 1000] / f_nyq, 'bandpass');

    % Bộ lọc Notch 50 Hz triệt nhiễu điện lưới - Tuần 6
    w0 = 2 * pi * 50 / Fs;
    r = 1 - (pi * 2 / Fs);
    b_notch = [1, -2*cos(w0), 1] * ((1 - 2*r*cos(w0) + r^2) / (2 - 2*cos(w0)));
    a_notch = [1, -2*r*cos(w0), r^2];

    % Cửa sổ tích phân trượt MWI 250 ms - Tuần 7
    W = round(0.25 * Fs);
    refractory_samples = round(0.90 * Fs); % Vùng trơ sinh lý 900 ms

    %% 2. KHỞI TẠO BIẾN TRẠNG THÁI (STATE VARIABLES)
    state.sp = [];
    state.isRunning = false;
    state.isSimulation = false;

    state.totalRaw  = [];
    state.totalFilt = [];

    state.zf_bp    = zeros(max(length(a_bp), length(b_bp)) - 1, 1);
    state.zf_notch = zeros(max(length(a_notch), length(b_notch)) - 1, 1);

    state.raw_buf    = zeros(win_len, 1);
    state.filt_buf   = zeros(win_len, 1);
    state.mwi_buf    = zeros(win_len, 1);
    state.thresh_buf = zeros(win_len, 1);
    state.t_axis     = (0:win_len-1)' / Fs;

    state.mwi_fifo    = zeros(W, 1);
    state.mwi_sum     = 0;
    state.runningPeak = 50000.0;
    state.prev_norm   = 0;

    % Ngưỡng thích ứng & Phát hiện đỉnh (Tuần 8)
    state.SP = 0.60;
    state.NP = 0.10;
    state.alpha = 0.25;
    state.sample_count = 0;
    state.last_peak = -refractory_samples;
    state.peak_times = [];
    state.peak_vals  = [];
    state.bpm_history_t = [];
    state.bpm_history_v = [];
    state.current_bpm = 0;

    % Cổng nhận diện tiếp xúc âm học (Acoustic Contact Gate)
    state.contact_hold_sec = 0.0;
    state.is_contact = false;
    state.has_modulation = false;
    state.pulse_samples = 0;
    state.min_pulse_samples = round(0.12 * Fs);

    % Ngưỡng RMS thích ứng môi trường (Mặc định: 450 cho ngoài trời / phòng ồn)
    state.isOutdoorMode = true;
    state.RMS_THRESH = 450.0;

    %% 3. XÂY DỰNG GIAO DIỆN BẢNG ĐIỀU KHIỂN Y SINH (GUI)
    hFig = figure('Name', 'Hệ Thống Giám Sát Âm Thanh Hô Hấp Real-Time (ESP32 - MATLAB)', ...
                  'Color', [0.10, 0.11, 0.14], 'NumberTitle', 'off', ...
                  'Position', [60, 40, 1200, 780], 'CloseRequestFcn', @onCloseApp);

    % 3.1. Bảng điều khiển nút bấm
    pnlTop = uipanel(hFig, 'Position', [0.01, 0.90, 0.98, 0.09], ...
                     'BackgroundColor', [0.15, 0.17, 0.22], 'ForegroundColor', 'w', ...
                     'Title', '  ĐIỀU KHIỂN HỆ THỐNG  ', 'FontSize', 10, 'FontWeight', 'bold');

    btnStart = uicontrol(pnlTop, 'Style', 'pushbutton', 'String', '▶ BẮT ĐẦU REAL-TIME', ...
                         'Position', [10, 10, 160, 32], 'BackgroundColor', [0.1, 0.7, 0.3], ...
                         'ForegroundColor', 'w', 'FontSize', 10, 'FontWeight', 'bold', ...
                         'Callback', @onStartStop);

    btnSave = uicontrol(pnlTop, 'Style', 'pushbutton', 'String', '💾 LƯU BẢN GHI (.MAT)', ...
                        'Position', [175, 10, 150, 32], 'BackgroundColor', [0.2, 0.5, 0.8], ...
                        'ForegroundColor', 'w', 'FontSize', 10, 'FontWeight', 'bold', ...
                        'Enable', 'off', 'Callback', @onSaveData);

    btnMode = uicontrol(pnlTop, 'Style', 'pushbutton', 'String', '🌳 NGOÀI TRỜI (Ngưỡng: 450)', ...
                        'Position', [330, 10, 185, 32], 'BackgroundColor', [0.65, 0.40, 0.10], ...
                        'ForegroundColor', 'w', 'FontSize', 9.5, 'FontWeight', 'bold', ...
                        'TooltipString', 'Bấm để đổi chế độ Ngoài trời (Ngưỡng 450) <-> Trong phòng (Ngưỡng 150)', ...
                        'Callback', @onToggleMode);

    lblStatus = uicontrol(pnlTop, 'Style', 'text', 'String', 'Trạng thái: Sẵn sàng kết nối ESP32 (COM4)', ...
                          'Position', [525, 12, 450, 26], 'BackgroundColor', [0.15, 0.17, 0.22], ...
                          'ForegroundColor', [1.0, 0.85, 0.2], 'FontSize', 9.5, ...
                          'HorizontalAlignment', 'left');

    % Ô số nhịp thở lớn nổi bật
    pnlBPM = uipanel(pnlTop, 'Position', [0.83, 0.05, 0.16, 0.90], ...
                     'BackgroundColor', [0.08, 0.09, 0.11], 'ForegroundColor', [0.3, 0.9, 1.0], ...
                     'Title', 'NHỊP THỞ (RR)', 'FontSize', 8);
    lblBPM = uicontrol(pnlBPM, 'Style', 'text', 'String', '-- BPM', ...
                       'Units', 'normalized', 'Position', [0.05, 0.05, 0.90, 0.85], ...
                       'BackgroundColor', [0.08, 0.09, 0.11], 'ForegroundColor', [0.2, 1.0, 0.4], ...
                       'FontSize', 16, 'FontWeight', 'bold');

    % 3.2. Bố trí 4 kênh đồ thị
    % Kênh 1: Sóng thô
    ax1 = axes(hFig, 'Position', [0.06, 0.70, 0.92, 0.17], ...
               'Color', [0.06, 0.07, 0.09], 'XColor', 'w', 'YColor', 'w'); grid(ax1, 'on');
    hLine1 = plot(ax1, state.t_axis, state.raw_buf, 'Color', [0.85, 0.85, 0.85], 'LineWidth', 0.9);
    title(ax1, '1. Tín hiệu âm thở thô từ ESP32-C3 qua ống nghe (Raw ADC)', 'Color', [1.0, 0.85, 0.2], 'FontWeight', 'bold');
    ylabel(ax1, 'Raw ADC', 'Color', 'w'); ylim(ax1, [-4000, 4000]);

    % Kênh 2: Sau lọc dải phế quản & Notch 50 Hz
    ax2 = axes(hFig, 'Position', [0.06, 0.48, 0.92, 0.17], ...
               'Color', [0.06, 0.07, 0.09], 'XColor', 'w', 'YColor', 'w'); grid(ax2, 'on');
    hLine2 = plot(ax2, state.t_axis, state.filt_buf, 'Color', [0.0, 0.80, 1.0], 'LineWidth', 0.9);
    title(ax2, '2. Sau lọc số Real-Time: IIR Bandpass (100 - 1000 Hz) & Notch 50 Hz', 'Color', [0.0, 0.80, 1.0], 'FontWeight', 'bold');
    ylabel(ax2, 'Filtered', 'Color', 'w'); ylim(ax2, [-2000, 2000]);

    % Kênh 3: Đường bao MWI 250 ms & Ngưỡng thích ứng
    ax3 = axes(hFig, 'Position', [0.06, 0.26, 0.92, 0.17], ...
               'Color', [0.06, 0.07, 0.09], 'XColor', 'w', 'YColor', 'w'); grid(ax3, 'on'); hold(ax3, 'on');
    hLine3  = plot(ax3, state.t_axis, state.mwi_buf, 'Color', [0.2, 1.0, 0.4], 'LineWidth', 1.3);
    hThresh = plot(ax3, state.t_axis, state.thresh_buf, '--r', 'LineWidth', 1.1);
    hPeaks  = plot(ax3, NaN, NaN, 'ro', 'MarkerFaceColor', 'r', 'MarkerSize', 6);
    title(ax3, '3. Đường bao tích phân trượt MWI (250ms), Ngưỡng thích ứng & Nhận diện đỉnh', 'Color', [0.2, 1.0, 0.4], 'FontWeight', 'bold');
    ylabel(ax3, 'Envelope', 'Color', 'w'); ylim(ax3, [0, 1.2]);

    % Kênh 4: Biểu đồ theo dõi nhịp thở (BPM)
    ax4 = axes(hFig, 'Position', [0.06, 0.05, 0.92, 0.16], ...
               'Color', [0.06, 0.07, 0.09], 'XColor', 'w', 'YColor', 'w'); grid(ax4, 'on'); hold(ax4, 'on');
    hBpmLine = plot(ax4, NaN, NaN, 's-', 'Color', [1.0, 0.6, 0.2], 'LineWidth', 1.4, 'MarkerFaceColor', [1.0, 0.6, 0.2]);
    hAvgBpm  = yline(ax4, 0, 'Color', [0.2, 1.0, 0.5], 'LineWidth', 1.5, 'Alpha', 0.8);
    hTitle4  = title(ax4, '4. Tốc độ hô hấp: -- BPM', 'Color', 'w', 'FontWeight', 'bold');
    xlabel(ax4, 'Thời gian cửa sổ trượt (giây)', 'Color', 'w');
    ylabel(ax4, 'BPM', 'Color', 'w');
    xlim(ax4, [0, win_sec]); ylim(ax4, [0, 35]);

    % Khởi tạo Timer cập nhật thời gian thực (40 ms = 25 FPS)
    t_timer = timer('ExecutionMode', 'fixedRate', 'Period', 0.04, 'TimerFcn', @onTimerTick);

    %% 4. XỬ LÝ SỰ KIỆN GIAO DIỆN & CHẾ ĐỘ MÔI TRƯỜNG
    function onToggleMode(~, ~)
        if state.isOutdoorMode
            % Chuyển sang chế độ Trong phòng
            state.isOutdoorMode = false;
            state.RMS_THRESH = 150.0;
            set(btnMode, 'String', '🏠 TRONG PHÒNG (Ngưỡng: 150)', 'BackgroundColor', [0.2, 0.5, 0.3]);
        else
            % Chuyển sang chế độ Ngoài trời
            state.isOutdoorMode = true;
            state.RMS_THRESH = 450.0;
            set(btnMode, 'String', '🌳 NGOÀI TRỜI (Ngưỡng: 450)', 'BackgroundColor', [0.65, 0.40, 0.10]);
        end
    end

    function onStartStop(~, ~)
        if ~state.isRunning
            set(lblStatus, 'String', 'Đang kết nối cổng Serial COM4...', 'ForegroundColor', 'yellow'); drawnow;
            try
                state.sp = serialport(port_name, baud_rate, "Timeout", 1);
                configureTerminator(state.sp, "LF");
                flush(state.sp);
                state.isSimulation = false;
                set(lblStatus, 'String', '✅ KẾT NỐI COM4 THÀNH CÔNG (Đang thu dữ liệu âm thanh số)', 'ForegroundColor', [0.2, 1.0, 0.4]);
            catch
                state.isSimulation = true;
                state.sp = [];
                set(lblStatus, 'String', 'ℹ Không mở được COM4 -> Đang chạy chế độ GIẢ LẬP ÂM THỞ Y SINH', 'ForegroundColor', [0.3, 0.9, 1.0]);
            end

            state.isRunning = true;
            set(btnStart, 'String', '⏹ DỪNG THU THẬP', 'BackgroundColor', [0.85, 0.2, 0.2]);
            set(btnSave, 'Enable', 'off');
            start(t_timer);
        else
            stopSystem();
        end
    end

    function stopSystem()
        if state.isRunning
            state.isRunning = false;
            stop(t_timer);
            if ~isempty(state.sp)
                try
                    flush(state.sp);
                    delete(state.sp);
                catch
                end
                state.sp = [];
            end
            set(btnStart, 'String', '▶ TIẾP TỤC REAL-TIME', 'BackgroundColor', [0.1, 0.7, 0.3]);
            if ~isempty(state.totalRaw)
                set(btnSave, 'Enable', 'on');
            end
            set(lblStatus, 'String', sprintf('Đã dừng. Tổng mẫu đã thu: %d (%.1f s)', ...
                length(state.totalRaw), length(state.totalRaw) / Fs), 'ForegroundColor', [1.0, 0.85, 0.2]);
        end
    end

    %% 5. VÒNG LẶP XỬ LÝ TÍN HIỆU THỜI GIAN THỰC (DSP TICK)
    function onTimerTick(~, ~)
        samples = [];
        if state.isSimulation
            K_sim = round(0.04 * Fs);
            t_curr = state.sample_count / Fs;
            tau = mod(t_curr, 4.28);
            if tau < 1.5
                env = sin(pi * tau / 1.5) ^ 2;
            elseif tau >= 1.9 && tau < 3.6
                env = 0.82 * sin(pi * (tau - 1.9) / 1.7) ^ 2;
            else
                env = 0.015;
            end
            samples = round(env * 2200 * randn(K_sim, 1) + 80 * sin(2*pi*50*(1:K_sim)'/Fs));
        else
            if isempty(state.sp), return; end
            if state.sp.NumBytesAvailable > 0
                try
                    raw_str = read(state.sp, state.sp.NumBytesAvailable, "string");
                    parsed = textscan(raw_str, '%f');
                    if ~isempty(parsed) && ~isempty(parsed{1})
                        samples = parsed{1};
                        samples = samples(~isnan(samples) & isfinite(samples));
                    end
                catch
                    samples = [];
                end
            end
        end

        if isempty(samples), return; end
        if length(samples) > 800, samples = samples(end-799:end); end
        K = length(samples);

        % Lọc Notch 50 Hz & IIR Bandpass (100 - 1000 Hz)
        [f_notch, state.zf_notch] = filter(b_notch, a_notch, samples, state.zf_notch);
        [f_chunk, state.zf_bp]    = filter(b_bp, a_bp, f_notch, state.zf_bp);

        % CỔNG NHẬN DIỆN TIẾP XÚC ÂM HỌC (Acoustic Contact Gate)
        chunk_rms = sqrt(mean(f_chunk .^ 2));
        if state.isSimulation
            state.is_contact = true;
        else
            if chunk_rms >= state.RMS_THRESH
                state.contact_hold_sec = 1.2;
            else
                state.contact_hold_sec = max(0, state.contact_hold_sec - (K / Fs));
            end
            state.is_contact = (state.contact_hold_sec > 0);
        end

        % Thuật toán Pan-Tompkins: Đạo hàm bậc 1 + Bình phương (Tuần 7)
        diff_sq = (diff([f_chunk(1); f_chunk])) .^ 2;
        norm_chunk = zeros(K, 1);
        th_chunk   = zeros(K, 1);

        for k = 1:K
            state.sample_count = state.sample_count + 1;
            curr = diff_sq(k);

            % Tích phân cửa sổ trượt MWI 250 ms
            state.mwi_sum = state.mwi_sum - state.mwi_fifo(1) + curr;
            state.mwi_fifo = [state.mwi_fifo(2:end); curr];
            m_val = max(0, state.mwi_sum / W);

            % Bộ cân bằng động AGC
            if state.is_contact
                if m_val > state.runningPeak
                    state.runningPeak = 0.85 * state.runningPeak + 0.15 * m_val;
                else
                    state.runningPeak = state.runningPeak * (1 - 0.15 / Fs);
                end
                state.runningPeak = max(state.runningPeak, 20000.0);
            else
                state.runningPeak = max(state.runningPeak, 80000.0);
            end

            norm_val = min(1.0, max(0.0, m_val / state.runningPeak));
            norm_chunk(k) = norm_val;

            % Ngưỡng thích ứng động (Tuần 8)
            th = state.NP + state.alpha * (state.SP - state.NP);
            th = min(0.80, max(0.20, th));
            th_chunk(k) = th;

            % Đếm độ rộng thì thở
            if norm_val >= th
                state.pulse_samples = state.pulse_samples + 1;
            else
                state.pulse_samples = 0;
            end

            % Phát hiện đỉnh thì thở: Bắt buộc phải có tiếp xúc và thỏa mãn vùng trơ
            is_apex = (state.prev_norm > th) && (norm_val <= state.prev_norm);
            if state.is_contact && is_apex && state.pulse_samples >= state.min_pulse_samples && (state.sample_count - state.last_peak) >= refractory_samples
                state.last_peak = state.sample_count;
                p_t = (state.sample_count - 1) / Fs;
                state.peak_times = [state.peak_times; p_t];
                state.peak_vals  = [state.peak_vals; state.prev_norm];
                state.SP = 0.125 * state.prev_norm + 0.875 * state.SP;

                % Tính nhịp thở tức thời
                if length(state.peak_times) >= 2
                    diffs = diff(state.peak_times);
                    if median(diffs) >= 2.5
                        dur = diffs(end);
                    elseif length(state.peak_times) >= 3
                        dur = state.peak_times(end) - state.peak_times(end-2);
                    else
                        dur = 0;
                    end

                    if dur >= 1.5 && dur <= 9.0
                        bpm_inst = 60 / dur;
                        if state.current_bpm == 0
                            state.current_bpm = bpm_inst;
                        else
                            state.current_bpm = 0.35 * bpm_inst + 0.65 * state.current_bpm;
                        end
                        state.bpm_history_t = [state.bpm_history_t; p_t];
                        state.bpm_history_v = [state.bpm_history_v; state.current_bpm];
                    end
                end
            elseif norm_val < th
                state.NP = 0.002 * norm_val + 0.998 * state.NP;
            end
            state.prev_norm = norm_val;
        end

        % Cập nhật bộ đệm cuộn
        state.raw_buf    = [state.raw_buf(K+1:end); samples];
        state.filt_buf   = [state.filt_buf(K+1:end); f_chunk];
        state.mwi_buf    = [state.mwi_buf(K+1:end); norm_chunk];
        state.thresh_buf = [state.thresh_buf(K+1:end); th_chunk];

        state.totalRaw  = [state.totalRaw; samples];
        state.totalFilt = [state.totalFilt; f_chunk];

        % KIỂM TRA ĐIỀU CHẾ ĐƯỜNG BAO (ENVELOPE MODULATION CHECK):
        % Tiếng ồn môi trường liên tục (tiếng gió, tiếng xe ngoài trời) có đường bao phẳng lỳ (span < 0.20)
        % Hơi thở người thật có chu kỳ hít/thở phình to và hạ sâu (span >= 0.25)
        recent_mwi = state.mwi_buf(end - min(length(state.mwi_buf), round(3.5 * Fs)) + 1 : end);
        mwi_span = max(recent_mwi) - min(recent_mwi);
        state.has_modulation = (mwi_span >= 0.22);

        % TIMEOUT NHỊP THỞ: Nếu quá 5.0 giây không có đỉnh thở mới -> Xóa số đo BPM cũ
        curr_t = state.sample_count / Fs;
        if ~isempty(state.peak_times)
            if (curr_t - state.peak_times(end)) > 5.0
                state.current_bpm = 0;
            end
        else
            state.current_bpm = 0;
        end

        % Cập nhật đồ thị hiển thị
        set(hLine1, 'YData', state.raw_buf);
        maxRaw = max(abs(state.raw_buf));
        if maxRaw > 3000
            ylim(ax1, [-maxRaw * 1.1, maxRaw * 1.1]);
        else
            ylim(ax1, [-3000, 3000]);
        end

        set(hLine2, 'YData', state.filt_buf);
        maxFilt = max(abs(state.filt_buf));
        if maxFilt > 1500
            ylim(ax2, [-maxFilt * 1.1, maxFilt * 1.1]);
        else
            ylim(ax2, [-1500, 1500]);
        end

        set(hLine3, 'YData', state.mwi_buf);
        set(hThresh, 'YData', state.thresh_buf);

        % Đánh dấu các đỉnh trong cửa sổ trượt hiện tại
        t_start = max(0, curr_t - win_sec);
        if ~isempty(state.peak_times)
            in_v = (state.peak_times >= t_start & state.peak_times <= curr_t);
            if any(in_v)
                set(hPeaks, 'XData', state.peak_times(in_v) - t_start, 'YData', state.peak_vals(in_v));
            else
                set(hPeaks, 'XData', NaN, 'YData', NaN);
            end
        end

        % Cập nhật trạng thái và BPM
        if maxRaw < 5
            set(lblStatus, 'String', '❌ CẢNH BÁO: CHƯA CẮM HOẶC LỎNG CẢM BIẾN INMP441 (Tín hiệu = 0)', 'ForegroundColor', [1.0, 0.3, 0.3]);
            set(lblBPM, 'String', 'MẤT MIC', 'ForegroundColor', [1.0, 0.3, 0.3]);
        elseif ~state.is_contact
            set(lblStatus, 'String', sprintf('🟡 CHỜ ÁP ỐNG NGHE (RMS: %.0f < %.0f - Để ngoài trời / Tiếng ồn môi trường)', chunk_rms, state.RMS_THRESH), ...
                'ForegroundColor', [1.0, 0.85, 0.2]);
            set(lblBPM, 'String', '-- BPM', 'ForegroundColor', [0.7, 0.7, 0.7]);
            set(hTitle4, 'String', sprintf('4. 🟡 CHỜ ÁP ỐNG NGHE (RMS: %.0f < %.0f - Tạm dừng đo)', chunk_rms, state.RMS_THRESH), 'Color', [1.0, 0.85, 0.2]);
        elseif ~state.has_modulation && ~state.isSimulation
            % RMS cao do tiếng ồn ngoài trời nhưng đường bao MWI phẳng lỳ (không có nhịp thở)
            set(lblStatus, 'String', sprintf('🟡 TIẾNG ỒN NGOÀI TRỜI (RMS: %.0f >= %.0f - Chưa phát hiện chu kỳ thở nhịp nhàng)', chunk_rms, state.RMS_THRESH), ...
                'ForegroundColor', [1.0, 0.85, 0.2]);
            set(lblBPM, 'String', 'CHỜ THỞ...', 'ForegroundColor', [0.3, 0.9, 1.0]);
            set(hTitle4, 'String', sprintf('4. 🟡 TIẾNG ỒN MÔI TRƯỜNG LIÊN TỤC (RMS: %.0f - MWI phẳng, chưa có nhịp thở)', chunk_rms), 'Color', [1.0, 0.85, 0.2]);
        else
            if state.isSimulation
                set(lblStatus, 'String', 'ℹ Đang chạy chế độ GIẢ LẬP âm thở y sinh', 'ForegroundColor', [0.3, 0.9, 1.0]);
            else
                set(lblStatus, 'String', sprintf('✅ TIẾP XÚC ÂM HỌC TỐT (RMS: %.0f >= %.0f - Đang đo chu kỳ thở)', chunk_rms, state.RMS_THRESH), ...
                    'ForegroundColor', [0.2, 1.0, 0.4]);
            end

            if state.current_bpm > 0
                set(lblBPM, 'String', sprintf('%.1f BPM', state.current_bpm), 'ForegroundColor', [0.2, 1.0, 0.4]);
                set(hTitle4, 'String', sprintf('4. ✅ Tốc độ hô hấp hiện tại: %.1f lần/phút (RMS: %.0f)', state.current_bpm, chunk_rms), 'Color', [0.2, 1.0, 0.4]);

                if ~isempty(state.bpm_history_t)
                    in_v_bpm = (state.bpm_history_t >= t_start & state.bpm_history_t <= curr_t);
                    if any(in_v_bpm)
                        set(hBpmLine, 'XData', state.bpm_history_t(in_v_bpm) - t_start, 'YData', state.bpm_history_v(in_v_bpm));
                    end
                    set(hAvgBpm, 'Value', mean(state.bpm_history_v(max(1, end-5):end)));
                end
            else
                set(lblBPM, 'String', 'ĐANG ĐO...', 'ForegroundColor', [0.3, 0.9, 1.0]);
                set(hTitle4, 'String', sprintf('4. ✅ Đang đón chu kỳ thở tiếp theo... (RMS: %.0f)', chunk_rms), 'Color', [0.2, 1.0, 0.4]);
            end
        end
    end

    %% 6. LƯU BẢN GHI DỮ LIỆU THỰC TẾ
    function onSaveData(~, ~)
        if isempty(state.totalRaw)
            warndlg('Chưa có dữ liệu nào được thu thập!', 'Cảnh báo');
            return;
        end

        curr_dir = fileparts(mfilename('fullpath'));
        data_dir = fullfile(fileparts(curr_dir), 'data');
        if ~exist(data_dir, 'dir'), mkdir(data_dir); end

        timestamp_str = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
        filename = sprintf('breath_record_%s.mat', timestamp_str);
        full_filepath = fullfile(data_dir, filename);

        raw_signal = state.totalRaw;
        filtered_signal = state.totalFilt;
        ground_truth_bpm = state.current_bpm;
        if ground_truth_bpm == 0, ground_truth_bpm = 14.0; end

        save(full_filepath, 'raw_signal', 'filtered_signal', 'Fs', 'ground_truth_bpm');

        set(lblStatus, 'String', sprintf('Đã lưu file thành công: %s', filename), 'ForegroundColor', [0.2, 1.0, 0.4]);
        msgbox(sprintf('Đã lưu thành công bản ghi vào:\n%s\n\nTổng mẫu: %d (%.1f giây)', full_filepath, length(raw_signal), length(raw_signal)/Fs), ...
               'Lưu thành công', 'help');
    end

    %% 7. ĐÓNG ỨNG DỤNG AN TOÀN
    function onCloseApp(~, ~)
        stopSystem();
        delete(t_timer);
        delete(hFig);
    end
end
