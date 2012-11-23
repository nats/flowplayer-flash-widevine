﻿/*
 * This file is part of Flowplayer, http://flowplayer.org
 *
 * By: Anssi Piirainen, <support@flowplayer.org>
 * Copyright (c) 2008 Flowplayer Ltd
 *
 * Released under the MIT License:
 * http://www.opensource.org/licenses/mit-license.php
 */

package org.flowplayer.rtmp {
    import flash.events.NetStatusEvent;
    import flash.events.Event;
import flash.utils.setTimeout;

CONFIG::WIDEVINE {
    import com.widevine.WvNetStream;
    import com.widevine.WvNetConnection;
    }
CONFIG::FLASH_10_1 {
    import flash.net.GroupSpecifier;
    }
    import flash.net.NetConnection;
    import flash.net.NetStream;

    import org.flowplayer.controller.ConnectionProvider;
    import org.flowplayer.controller.NetStreamControllingStreamProvider;
    import org.flowplayer.model.Clip;
    import org.flowplayer.model.ClipEvent;
    import org.flowplayer.model.ClipEventType;
    import org.flowplayer.model.Plugin;
    import org.flowplayer.model.PluginModel;
    import org.flowplayer.util.PropertyBinder;
    import org.flowplayer.util.URLUtil;
    import org.flowplayer.util.VersionUtil;
    import org.flowplayer.view.Flowplayer;


    /**
	 * A RTMP stream provider. Supports following:
	 * <ul>
	 * <li>Starting in the middle of the clip's timeline using the clip.start property.</li>
	 * <li>Stopping before the clip file ends using the clip.duration property.</li>
	 * <li>Ability to combine a group of clips into one gapless stream.</li>
	 * </ul>
	 * <p>
	 * Stream group is configured in a clip like this:
	 * <code>
	 * { streams: [ { url: 'metacafe', duration: 20 }, { url: 'honda_accord', start: 10, duration: 20 } ] }
	 * </code>
	 * The group is played back seamlessly as one gapless stream. The individual streams in a group can
	 * be cut out from a larger file using the 'start' and 'duration' properties as shown in the example above.
	 *
	 * @author api
	 */
	public class RTMPStreamProvider extends NetStreamControllingStreamProvider implements Plugin {

		private var _config : Config;
		private var _model : PluginModel;
		private var _bufferStart : Number = 0;
		private var _player : Flowplayer;
		private var _rtmpConnectionProvider : ConnectionProvider;
		private var _subscribingConnectionProvider : ConnectionProvider;
		private var _durQueryingConnectionProvider : ConnectionProvider;
		private var _previousClip : Clip;
		private var _dvrLiveStarted : Boolean;
		private var _receivedStop : Boolean;
        private var _stepping:Boolean;
        private var _endSeekBuffer:Number = 0.1;
        private var _reconnecting:Boolean;
        private var _reconnectTime:Number = -1;
        private var _id3Stream:NetStream;
        private var _streamsStarted:Boolean;
        private var _hasNext:Boolean;

        override protected function createNetStream(connection:NetConnection):NetStream {
            CONFIG::WIDEVINE {
                if (clip.extension == "wvm") {
                    log.debug("createNetStream(), (widevine)");
                    return new WidevineNetStream(connection as WvNetConnection);
                }
            }

            CONFIG::FLASH_10_1 {
                if (clip.getCustomProperty("p2pGroupSpec")) {
                    return createP2PStream(connection);
                }
            }
            log.debug("createNetStream(), (non p2p)");
            return new NetStream(connection);
        }

        CONFIG::FLASH_10_1
        private function createP2PStream(connection:NetConnection):NetStream {
            log.debug("createP2PStream(), p2pGroup == " + String(clip.getCustomProperty("p2pGroupSpec")));
            return new NetStream(connection, String(clip.getCustomProperty("p2pGroupSpec")));
        }

        CONFIG::FLASH_10_1
        override protected function onNetStreamCreated(netStream:NetStream):void {
            if (netStream.hasOwnProperty("backBufferLength")) {
                log.debug("setting backBufferLength to " + clip.backBufferLength + " seconds");
                netStream.backBufferTime = clip.backBufferLength;
                netStream.inBufferSeek = _config.inBufferSeek;
            }
        }

        override protected function onNetStatus(event:NetStatusEvent) : void {
            log.info("onNetStatus(), code: " + event.info.code + ", paused? " + paused + ", seeking? " + seeking);
            switch(event.info.code){
				// Widevine sends Seek.Complete after its finished seeking; 
				// until this is received the time is not correct
				case "NetStream.Seek.Complete":
					dispatchEvent(new ClipEvent(ClipEventType.SEEK, time));
					break;
                case "NetStream.Play.Start":
                    if (_stepping) return;
                    if (paused){
                        dispatchEvent(new ClipEvent(ClipEventType.SEEK, seekTarget));
                        seeking = false;
                    }
                    if (_config.dvrSubscribeLive && !_dvrLiveStarted){
                        netStream.seek(1000000);
                        _dvrLiveStarted = true;
                    }

                    //#593 if this clip has a stream group, prevent onbegin from dispatching during playback.
                    if (hasStreamGroup(clip)) _streamsStarted = true;

                    break;
                case "NetStream.Play.Stop":
                    _stepping = false;
				    _receivedStop = true;
                    _streamsStarted = false;
                    _hasNext = _player.playlist.hasNext();
                    break;
                case "NetStream.Buffer.Empty":
                    if (_stepping) return;
                    //#614 check if the current playlist item is the previously loaded item to prevent ending early as the provider stream is still open.
                    //if (_currentClip.type.type == "audio") {
                        //doStop(null, netStream, true);
                        //clip.dispatchBeforeEvent(new ClipEvent(ClipEventType.BUFFER_FULL));
                    //    return;
                   // }
                //case "NetStream.Buffer.Flush":
                    // #107, dispatch finish when we already got a stop
                    // #113, dispatch finish also when we're around the end of the clip
                    // && clip. duration > 0 added for this http://flowplayer.org/forum/8/46963
                    // #403 when seeking to the duration the buffer will flush and needs to end correctly
                    //#614 also test if there is no more playlist items left to dispatch finish.
                    if ((_receivedStop || clip.duration - _player.status.time < 1 && clip.duration > 0) && !_hasNext) {
                        clip.dispatchBeforeEvent(new ClipEvent(ClipEventType.FINISH));
                    }
                    break;
                case "NetStream.Play.Transition":
                    log.debug("Stream Transition -- " + event.info.details);
                    dispatchEvent(new ClipEvent(ClipEventType.SWITCH, event.info.details));
                    break;
                case "NetStream.Play.Failed":
                case "NetStream.Failed":
                    log.debug("Stream Transition Failed -- " + event.info.description);
                    dispatchEvent(new ClipEvent(ClipEventType.SWITCH_FAILED, event.info.description));
                    switchStreamNative();
                    break;
                case "NetStream.Step.Notify":
                    _stepping = true;
                break;
                case "NetStream.Unpause.Notify":
                    _stepping = false;
                break;
                case "NetConnection.Connect.NetworkChange":
                    //#430 on intermittent client connection failures, attempt a reconnect, or wait until connection is active again for rtmp connections.
                    //Do not attempt to connect here, this may be done in the connection providers.
                    if (_reconnectTime < 0) _reconnectTime = time;
                    _reconnecting = true;
                break;
            }

            return;
        }

        private function onPlayStatus(event:ClipEvent) : void {
            log.debug("onPlayStatus() -- " + event.info.code, event.info);
            if (event.info.code == "NetStream.Play.TransitionComplete"){
                dispatchEvent(new ClipEvent(ClipEventType.SWITCH_COMPLETE));
            }
            return;
        }

        override protected function canDispatchBegin():Boolean {
            return !_stepping && !_streamsStarted;
        }

		/**
		 * Called by the player to set my model object.
		 */
		override public function onConfig(model : PluginModel) : void {
			log.debug("onConfig()");
			if (_model) return;
			_model = model;
			_config = new PropertyBinder(new Config(), null).copyProperties(model.config) as Config;
		}

		/**
		 * Called by the player to set the Flowplayer API.
		 */
		override public function onLoad(player : Flowplayer) : void {
			_player = player;
			if (_config.streamCallbacks) {
				log.debug("configuration has " + _config.streamCallbacks + " stream callbacks");
			} else {
				log.debug("no stream callbacks in config");
			}

			_model.dispatchOnLoad();
//			_model.dispatchError(PluginError.INIT_FAILED, "failed for no fucking reason");
		}

		public function get durationFunc() : String {
			return clip.getCustomProperty("rtmpDurationFunc") as String || _config.durationFunc;
		}

		override protected function getConnectionProvider(clip : Clip) : ConnectionProvider {

			CONFIG::WIDEVINE {
				if (clip.extension == "wvm") {
					_rtmpConnectionProvider = new WidevineConnectionProvider(_config);
					return _rtmpConnectionProvider;
				}
			}
			if (clip.getCustomProperty("rtmpSubscribe") || _config.subscribe) {
				log.debug("using FCSubscribe to connect");
				if (!_subscribingConnectionProvider) {
					_subscribingConnectionProvider = new SubscribingRTMPConnectionProvider(_config);
				}
				return _subscribingConnectionProvider;
			}
			if (durationFunc) {
				log.debug("using " + durationFunc + " to fetch stream duration from the server");
				if (!_durQueryingConnectionProvider) {
					_durQueryingConnectionProvider = new DurationQueryingRTMPConnectionProvider(_config, durationFunc);
				}
				return _durQueryingConnectionProvider;
			}
			log.debug("using the default connection provider");
			if (!_rtmpConnectionProvider) {
				_rtmpConnectionProvider = new RTMPConnectionProvider(_config);
			}
			return _rtmpConnectionProvider;
		}

		/**
		 * Overridden to allow random seeking in the timeline.
		 */
		override public function get allowRandomSeek() : Boolean {
			return true;
		}


		/**
		 * Starts loading using the specified netStream and clip.
		 */
		override protected function doLoad(event : ClipEvent, netStream : NetStream, clip : Clip) : void {
			_bufferStart = 0;
            _stepping = false;
            _streamsStarted = false;
			if (hasStreamGroup(clip)) {
				startStreamGroup(clip, netStream);
			} else {
				startStream(clip);
			}
		}

        /**
         * onId3 obtain the metadata for an mp3 stream
         * @param info
         */
        public function onId3(info:Object):void
        {
            clip.metaData = info;
            clip.dispatch(ClipEventType.METADATA);
            _id3Stream.close();
            _id3Stream = null;
        }

		private function startStream(clip : Clip) : void {
			_receivedStop = false;
			var streamName : String = getStreamName(clip);
            
			var start : int = clip.start > 0 ? clip.start : 0;
			var duration : int = clip.duration > 0 ? clip.duration + 1 /* let some time to the duration tracker */: -1;
			
			log.debug("startStream() starting playback of stream '" + streamName + "', start: " + start + ", duration: " + duration);

            clip.onPlayStatus(onPlayStatus);



			if ( clip.live ) {
				netStream.play(streamName, -1);
			} else if (_config.dvrSubscribeStart || _config.dvrSubscribeLive) {
				netStream.play(streamName, 0, -1);
			} else {
				netStream.play(streamName, start, duration);
			}

            //#545 for mp3 streams, we need to call the file with an id3 prefix on the server to obtain the metadata
            if (clip.type.type == "audio") {
                if (!_id3Stream) _id3Stream = new NetStream(this.netConnection);
                _id3Stream.client = this;
				_id3Stream.addEventListener(Event.ID3,onId3);
                _id3Stream.play("id3:" + streamName.slice(4));
            }
		}

		private function getStreamName(clip : Clip) : String {
            log.debug("getStreamName() " + clip);
            //#494 generate the complete url only if a base url is set. regression caused by #412.
			var url : String = (clip.baseUrl ? clip.completeUrl : clip.url);

            //#439 just check for an rtmp complete url when parsing complete urls to allow other complete urls used for re-streaming to pass through.
			if (URLUtil.isRtmpUrl(url)) {
                //TODO: Parse rtmp complete urls correctly.
				var lastSlashPos : Number = url.lastIndexOf("/");
				return url.substring(lastSlashPos + 1);
			}
			return clip.url;
		}

		/**
		 * Overridden to be able to store the latest seek target position.
		 */
		override protected function doSeek(event : ClipEvent, netStream : NetStream, seconds : Number) : void {
			_receivedStop = false;
            //#424 force an end seek buffer to allow some playback and prevent hanging when seeking to the duration.
            seconds = (seconds >= clip.duration ? clip.duration - _endSeekBuffer : seconds);
            //#534 don't round seek times for frame accurate seeking
            //var time:int = int(seconds);
			_bufferStart = seconds;
			
			super.doSeek(event, netStream, seconds);
		}

		override protected function doSwitchStream(event : ClipEvent, netStream : NetStream, clip : Clip, netStreamPlayOptions : Object = null) : void {
            _receivedStop = false;
			_previousClip = clip;

            //#406 don't run version checks here anymore to work with Flash 11
			if (netStreamPlayOptions) {
                import flash.net.NetStreamPlayOptions;
                if (netStreamPlayOptions is NetStreamPlayOptions) {
					log.debug("doSwitchStream() calling play2()")
					netStream.play2(netStreamPlayOptions as NetStreamPlayOptions);
				}
			} else {
                //fix for #338, don't set the currentTime when dynamic stream switching
                _bufferStart = clip.currentTime;
                clip.currentTime = Math.floor(_previousClip.currentTime + netStream.time);
				switchStreamNative();
                dispatchEvent(event);
			}
		}

        private function switchStreamNative() : void {
            log.debug("Switching stream with netstream time: " + clip.currentTime);
            netStream.play(clip.url, clip.live ? (-1) : (clip.currentTime));
            return;
        }

		override public function get bufferStart() : Number {
			if (!clip) return 0;
            if (!netStream) return 0;
            var backBuffer:Number = 0;

            CONFIG::FLASH_10_1 {
            backBuffer = netStream.backBufferLength;
            }
            //var backBuffer:Number = netStream.hasOwnProperty("backBufferLength") ? netStream.backBufferLength : 0;
            //var backBuffer:Number = netStream.backBufferLength;
			return Math.max(0, getCurrentPlayheadTime(netStream) - backBuffer);
		}

		override public function get bufferEnd() : Number {
            if (!clip) return 0;
            if (!netStream) return 0;
			return getCurrentPlayheadTime(netStream) + netStream.bufferLength;
		}

		/**
		 * Starts streaming a stream group.
		 */
		protected function startStreamGroup(clip : Clip, netStream : NetStream) : void {
			var streams : Array = clip.customProperties.streams as Array;
			_receivedStop = false;
			log.debug("starting a group of " + streams.length + " streams");
			var totalDuration : int = 0;
			for (var i : Number = 0;i < streams.length;i++) {
				var stream : Object = streams[i];
				var duration : int = getDuration(stream);
				var reset : Object = i == 0 ? 1 : 0; 
				netStream.play(stream.url, getStart(stream), duration, reset);
				if (duration > 0) {
					totalDuration += duration;
				}
				log.debug("added " + stream.url + " to playlist, total duration " + totalDuration);
			}
			if (totalDuration > 0) {
				clip.duration = totalDuration;
			}
		}

		/**
		 * Does the specified clip have a configured stream group?
		 */
		protected function hasStreamGroup(clip : Clip) : Boolean {
			return clip.customProperties && clip.customProperties.streams;
		}

		private function getDuration(stream : Object) : int {
			return stream.duration || -1;
		}

		private function getStart(stream : Object) : int {
			return stream.start || 0;
		}

		public function getDefaultConfig() : Object {
			return null;
		}

		override public function get type() : String {
			return "rtmp";	
		}

		override public function get time() : Number {
			if (!netStream) return 0;
			return getCurrentPlayheadTime(netStream) + clip.currentTime;
		}

        //#363 overridable pause to frame for different seek functionality.
        override protected function pauseToFrame():void
        {
            //#594 when pausing to a frame, set a 100ms timeout to pause instead of a seek which was causing some streams to hang.
            setTimeout(function():void {
                log.debug("seeking to frame zero");
                //#363 pause stream here after metadata or else no metadata is sent for rtmp clips
                pause(new ClipEvent(ClipEventType.PAUSE));

                //#363 silent seek and force to seek to a frame or else video will not display
                silentSeek = true;
                pauseAfterStart = false;

                //#486 unmute when auto buffering and pausing to a frame.
                _player.muted = false;
            }, 100);


        }

        override protected function onMetaData(event:ClipEvent):void
        {
            super.onMetaData(event);
            //#430 if there is a client connection failure reconnect to the specified time for rtmp streams.
            if (_reconnecting) {
                seek(null, _reconnectTime);
                _reconnectTime = -1;
                _reconnecting = false;
            }

        }
	}
}
