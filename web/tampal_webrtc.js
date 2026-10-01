/**
 * tampal_webrtc.js
 * 
 * Native JavaScript WebRTC bridge for Tampal.
 * Called from Dart via dart:js_interop / js_interop_unsafe.
 * 
 * Exposes a global `TampalRTC` object with methods:
 *   TampalRTC.createOffer(signalBaseUrl, roomCode, onMessage, onStateChange)
 *   TampalRTC.joinWithAnswer(signalBaseUrl, roomCode, onMessage, onStateChange)
 *   TampalRTC.sendMessage(json)
 *   TampalRTC.close()
 */

(function () {
  'use strict';

  const ICE_SERVERS = [
    { urls: 'stun:stun.l.google.com:19302' },
    { urls: 'stun:stun1.l.google.com:19302' },
  ];

  let _pc = null;
  let _channel = null;
  let _onMessage = null;
  let _onStateChange = null;
  let _pollingInterval = null;
  let _answerPoller = null;
  let _knownCandidateCount = 0;

  function cleanup() {
    if (_pollingInterval) clearInterval(_pollingInterval);
    _pollingInterval = null;
    if (_answerPoller) clearInterval(_answerPoller);
    _answerPoller = null;
    _knownCandidateCount = 0;
  }

  async function postSignal(base, room, type, body, side) {
    const url = new URL(`${base}/api/signal`);
    url.searchParams.set('room', room);
    url.searchParams.set('type', type);
    if (side) url.searchParams.set('side', side);
    await fetch(url.toString(), {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
  }

  async function getSignal(base, room, type, side) {
    const url = new URL(`${base}/api/signal`);
    url.searchParams.set('room', room);
    url.searchParams.set('type', type);
    if (side) url.searchParams.set('side', side);
    const res = await fetch(url.toString());
    return res.json();
  }

  function setupChannel(channel) {
    _channel = channel;
    channel.onopen = () => {
      cleanup();
      if (_onStateChange) _onStateChange('connected');
    };
    channel.onclose = () => {
      if (_onStateChange) _onStateChange('disconnected');
    };
    channel.onerror = () => {
      if (_onStateChange) _onStateChange('error');
    };
    channel.onmessage = (e) => {
      if (_onMessage) _onMessage(e.data);
    };
  }

  function setupPeerEvents(pc, signalBase, room, localSide) {
    pc.oniceconnectionstatechange = () => {
      const state = pc.iceConnectionState;
      // Let channel.onopen be the sole authority for 'connected' so we don't emit duplicates.
      if (state === 'failed' || state === 'disconnected' || state === 'closed') {
        if (_onStateChange) _onStateChange(state);
      }
    };
    pc.onicecandidate = async (e) => {
      if (e.candidate) {
        await postSignal(signalBase, room, 'ice', { candidate: JSON.stringify(e.candidate) }, localSide);
      }
    };
  }

  async function pollForRemoteIce(pc, signalBase, room, remoteSide) {
    _pollingInterval = setInterval(async () => {
      try {
        const { candidates } = await getSignal(signalBase, room, 'ice', remoteSide);
        if (!candidates) return;
        for (let i = _knownCandidateCount; i < candidates.length; i++) {
          const c = new RTCIceCandidate(JSON.parse(candidates[i]));
          await pc.addIceCandidate(c);
          _knownCandidateCount++;
        }
      } catch (_) {}
    }, 500);
  }

  window.TampalRTC = {

    /**
     * Caller side: create offer, push to signaling, wait for answer.
     */
    createOffer: async function (signalBase, room, onMessage, onStateChange) {
      if (_pc) window.TampalRTC.close();
      _onMessage = onMessage;
      _onStateChange = onStateChange;

      const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
      _pc = pc;

      // Create the data channel
      const channel = pc.createDataChannel('tampal', { ordered: true });
      setupChannel(channel);
      setupPeerEvents(pc, signalBase, room, 'a');

      // Create offer
      const offer = await pc.createOffer();
      await pc.setLocalDescription(offer);

      // Wait a moment for ICE gathering to start, then push offer
      await new Promise(r => setTimeout(r, 400));
      await postSignal(signalBase, room, 'offer', { sdp: JSON.stringify(pc.localDescription) });

      if (_onStateChange) _onStateChange('waiting');

      // Poll for answer
      _answerPoller = setInterval(async () => {
        try {
          const { sdp } = await getSignal(signalBase, room, 'answer');
          if (sdp) {
            clearInterval(_answerPoller);
            _answerPoller = null;
            await pc.setRemoteDescription(new RTCSessionDescription(JSON.parse(sdp)));
            // Now start polling for B's ICE candidates
            await pollForRemoteIce(pc, signalBase, room, 'b');
          }
        } catch (_) {}
      }, 600);
    },

    /**
     * Answerer side: fetch offer, create answer, push to signaling.
     */
    joinWithAnswer: async function (signalBase, room, onMessage, onStateChange) {
      if (_pc) window.TampalRTC.close();
      _onMessage = onMessage;
      _onStateChange = onStateChange;

      const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
      _pc = pc;

      // Answer side receives the data channel
      pc.ondatachannel = (e) => setupChannel(e.channel);
      setupPeerEvents(pc, signalBase, room, 'b');

      // Fetch offer (poll until available)
      let sdp = null;
      for (let i = 0; i < 30; i++) {
        const res = await getSignal(signalBase, room, 'offer');
        if (res.sdp) { sdp = res.sdp; break; }
        await new Promise(r => setTimeout(r, 500));
      }

      if (!sdp) {
        if (_onStateChange) _onStateChange('error');
        return;
      }

      await pc.setRemoteDescription(new RTCSessionDescription(JSON.parse(sdp)));

      const answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      await new Promise(r => setTimeout(r, 400));
      await postSignal(signalBase, room, 'answer', { sdp: JSON.stringify(pc.localDescription) });

      if (_onStateChange) _onStateChange('connecting');

      // Poll for A's ICE candidates
      await pollForRemoteIce(pc, signalBase, room, 'a');
    },

    /** Send a JSON message over the data channel */
    sendMessage: function (json) {
      if (_channel && _channel.readyState === 'open') {
        _channel.send(json);
        return true;
      }
      return false;
    },

    /** Close and clean up */
    close: function () {
      cleanup();
      _onMessage = null;
      _onStateChange = null;
      if (_channel) { try { _channel.close(); } catch (_) {} _channel = null; }
      if (_pc) { try { _pc.close(); } catch (_) {} _pc = null; }
    },

    isConnected: function () {
      return _channel !== null && _channel.readyState === 'open';
    },
  };
})();
