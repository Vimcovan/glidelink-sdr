classdef Radio < handle
    %RADIO One GlideLink board through its bridge (sw/bridge/glidelink_bridge.py, TCP 7030).
    %
    %   r = glidelink.Radio("192.168.4.1");
    %   r.config(Rate=1e6, Freq=915e6, Bandwidth=1e6, TxAtten=20);
    %   r.txCyclic(x);              % complex column, |x| <= 1: repeated on the board
    %   y = r.rx(1e6);              % 1e6 contiguous samples, complex double, full scale 1
    %   r.txStop();
    %   w = r.host1(words, m);      % uint32 words through host port 1, m words back
    %   r.route(struct("slot0_in", "host1_tx", "host1_rx", "slot0_out"));
    %   v = r.reg("FPGA", hex2dec("004"));        % read; r.reg(iface, addr, value) writes
    %
    %   Samples travel as CS16 (12-bit full scale: 2048 = 1.0), as with Soapy and GNU Radio.

    properties (SetAccess = private)
        Host
        Settings        % last settings read back from the board (struct)
    end
    properties (Access = private)
        T               % tcpclient
    end

    methods
        function obj = Radio(host, port)
            arguments
                host (1,1) string
                port (1,1) double = 7030
            end
            obj.Host = host;
            obj.T = tcpclient(host, port, "Timeout", 30, "ConnectTimeout", 5);
            obj.Settings = obj.request(struct("cmd", "info"));
        end

        function s = config(obj, opts)
            %CONFIG Rate, Freq (both LOs), RxFreq, TxFreq, Bandwidth, RxGainMode
            %("slow_attack" / "fast_attack" / "manual"), RxGain (dB, manual), TxAtten (dB),
            %Loopback (AD9361 digital loopback, 0 / 1).
            arguments
                obj
                opts.Rate double
                opts.Freq double
                opts.RxFreq double
                opts.TxFreq double
                opts.Bandwidth double
                opts.RxGainMode string
                opts.RxGain double
                opts.TxAtten double
                opts.Loopback double
            end
            map = struct("Rate", "rate", "Freq", "freq", "RxFreq", "rx_freq", "TxFreq", "tx_freq", ...
                "Bandwidth", "bandwidth", "RxGainMode", "rx_gain_mode", "RxGain", "rx_gain", ...
                "TxAtten", "tx_atten", "Loopback", "loopback");
            req = struct("cmd", "config");
            for f = string(fieldnames(opts))'
                req.(map.(f)) = opts.(f);
            end
            s = obj.request(req);
            obj.Settings = s;
        end

        function txCyclic(obj, x)
            %TXCYCLIC Send the complex waveform x (|x| <= 1) repeatedly until txStop.
            obj.request(struct("cmd", "tx_cyclic"), glidelink.Radio.toCs16(x));
        end

        function txStop(obj)
            obj.request(struct("cmd", "tx_stop"));
        end

        function y = rx(obj, n)
            %RX n contiguous samples (captured on the board, then sent), complex double.
            [~, data] = obj.request(struct("cmd", "rx", "n", n));
            v = double(typecast(data, "int16")) / 2048;
            y = complex(v(1:2:end), v(2:2:end));
            y = y(:);
        end

        function w = host1(obj, words, m)
            %HOST1 uint32 words to host port 1, m words back (routes set with route()).
            [~, data] = obj.request(struct("cmd", "host1", "n_out", m), typecast(uint32(words(:)'), "uint8"));
            w = typecast(data, "uint32");
            w = w(:);
        end

        function route(obj, routes)
            %ROUTE sink <- source, as a struct: route(struct("slot0_in", "host1_tx"))
            obj.request(struct("cmd", "route", "routes", routes));
        end

        function v = reg(obj, iface, addr, value)
            req = struct("cmd", "reg", "iface", iface, "addr", addr);
            if nargin > 3
                req.value = value;
            end
            v = obj.request(req).value;
        end

        function delete(obj)
            obj.T = [];
        end
    end

    methods (Access = private)
        function [rep, data] = request(obj, req, payload)
            if nargin > 2
                req.bytes = numel(payload);
            end
            writeline(obj.T, jsonencode(req));
            if nargin > 2
                write(obj.T, payload, "uint8");
            end
            rep = jsondecode(char(readline(obj.T)));
            if ~rep.ok
                error("glidelink:bridge", "%s: %s", obj.Host, rep.error);
            end
            data = uint8([]);
            if isfield(rep, "bytes") && rep.bytes > 0
                data = read(obj.T, rep.bytes, "uint8");
            end
        end
    end

    methods (Static)
        function b = toCs16(x)
            x = x(:);
            v = round(2047 * [real(x).'; imag(x).']);
            v = min(max(v, -2048), 2047);
            b = typecast(int16(v(:)'), "uint8");
        end
    end
end
