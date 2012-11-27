﻿/*
 * Author: Thomas Dubois, <thomas _at_ flowplayer org>
 * This file is part of Flowplayer, http://flowplayer.org
 *
 * Copyright (c) 2011 Flowplayer Ltd
 *
 * Released under the MIT License:
 * http://www.opensource.org/licenses/mit-license.php
 */
package org.flowplayer.controls.controllers {
    
	import org.flowplayer.view.Flowplayer;
	import org.flowplayer.model.PlayerEvent;
	import org.flowplayer.model.ClipEvent;
	
	import org.flowplayer.ui.controllers.AbstractToggleButtonController;
	import org.flowplayer.ui.buttons.ToggleButtonConfig;
	import org.flowplayer.ui.buttons.ButtonEvent;
	import org.flowplayer.ui.buttons.ToggleButton;
	
	import org.flowplayer.controls.Controlbar;
	import org.flowplayer.controls.SkinClasses;

	import flash.display.DisplayObjectContainer;
	
	public class TogglePlayButtonController extends AbstractToggleButtonController {

		public function TogglePlayButtonController() {
			super();
		}
		
		override public function get name():String {
			return "play";
		}
		
		override public function get defaults():Object {
			return {
				tooltipEnabled: false,
				tooltipLabel: "Play",
				visible: true,
				enabled: true
			};
		}
		
		override public function get downName():String {
			return "pause";
		}
		
		override public function get downDefaults():Object {
			return {
				tooltipEnabled: false,
				tooltipLabel: "Pause",
				visible: true,
				enabled: true
			};
		}

		// get it included in swc
		override protected function get faceClass():Class {
			return SkinClasses.getClass("fp.PlayButton");
		}
		
		override protected function get downFaceClass():Class {
			return SkinClasses.getClass("fp.PauseButton");
		}
		
		override protected function onButtonClicked(event:ButtonEvent):void {
			_player.toggle();
		}
		
		// handle state
		override protected function onPlayStarted(event:ClipEvent):void {		
            isDown = ! event.isDefaultPrevented() && _player.isPlaying();
        }

        override protected function onPlayPaused(event:ClipEvent):void {
            log.debug("onPlayPaused()");
            isDown = false;
        }
        
        override protected function onPlayResumed(event:ClipEvent):void {
            log.debug("onPlayResumed()");
            isDown = true;
		}
		
		override protected function onPlayStopped(event:ClipEvent):void {
            isDown = false;
        }
	}
}
