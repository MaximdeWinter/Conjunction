// conjunction editor camera: flies freely while the editor is on. The companion app sends the key state (WASD, space,
// ctrl, shift) and mouse-look deltas; a timer integrates them every frame and moves the camera ONLY WHEN THE POSE
// CHANGED.
//
// The camera is a real camera entity (CStaticCamera, the one the game uses for posters), not the engine's debug free
// camera: Maxim compared both in the game - the entity is "the perfect one" (the debug free camera throws away the
// TAA / DLSS history on every move, the picture shimmered; called every frame even at rest: 60 % of the image changed,
// 15 % on changes only, 11 % with the gameplay camera). The debug free camera is only a fallback if the entity cannot
// be made. Keep both rules: entity camera, and move it only when the pose changed.
//
// The entity looks along its -Y: given (pitch, yaw) it looks exactly opposite to CjFlyAxes' forward, so it gets
// (-pitch, yaw + 180) - measured, without it every direction was inverted.
// EnableFreeCamera(false) puts the game's input back to gameplay (Geralt walks with WASD, right click = witcher
// senses, no cursor) - it is only called when the free camera really was on.
// Input older than 0.25 s counts as released: a companion app that died cannot leave a key stuck. Every new pose is
// reported (cam|...), the app draws the gizmo with it (in its overlay: Maxim 29.09. - the overlay is the simpler way;
// a gizmo lagging a little while flying does not matter, it is only used while the camera stands still).

@addField(CR4Player)
var w3sFlyOn : bool;
@addField(CR4Player)
var w3sFlyPos : Vector;
@addField(CR4Player)
var w3sFlyRot : EulerAngles;
@addField(CR4Player)
var w3sFlyGoal : EulerAngles;   // where the mouse turned the camera to: w3sFlyRot glides there every frame
@addField(CR4Player)
var w3sFlyIn : Vector;          // x = forward, y = right, z = up (-1..1); W = speed factor
@addField(CR4Player)
var w3sFlyInTime : float;
@addField(CR4Player)
var w3sFlyLast : Vector;        // the pose last given to the camera
@addField(CR4Player)
var w3sFlyLastRot : EulerAngles;
@addField(CR4Player)
var w3sFlyCam : CStaticCamera;
@addField(CR4Player)
var w3sFlyFree : bool;          // fallback: the debug free camera is on
@addField(CR4Player)
var w3sFlyHome : Vector;        // where Geralt stood when the editor opened (he goes back there)
@addField(CR4Player)
var w3sFlyHomeRot : EulerAngles;
@addField(CR4Player)
var w3sFlyAway : bool;          // he follows the camera (hidden) - the world loads around him, not the camera

@addMethod(CR4Player)
function CjFlyReport() {
    var f, r, u : Vector;
    CjFlyAxes(f, r, u);
    CjOut("cam|" + FloatToString(w3sFlyPos.X) + "|" + FloatToString(w3sFlyPos.Y) + "|"
        + FloatToString(w3sFlyPos.Z) + "|" + FloatToString(w3sFlyRot.Pitch) + "|" + FloatToString(w3sFlyRot.Yaw) + "|"
        + FloatToString(f.X) + "|" + FloatToString(f.Y) + "|" + FloatToString(f.Z) + "|" + FloatToString(theCamera.GetFov()));
}

// the rotation the camera entity needs to look along CjFlyAxes' forward
@addMethod(CR4Player)
function CjFlyEntityRot() : EulerAngles {
    return EulerAngles(-w3sFlyRot.Pitch, AngleNormalize(w3sFlyRot.Yaw + 180), 0);
}

// where the entity must stand so that its camera is at w3sFlyPos: the poster camera template's camera sits 1.28 m
// behind and 1.46 m above the entity (measured at five rotations, always the same in the camera's frame)
@addMethod(CR4Player)
function CjFlyEntityPos() : Vector {
    var f, r, u, p : Vector;
    CjFlyAxes(f, r, u);
    p = w3sFlyPos + f * 1.28 - u * 1.46;
    p.W = 1;
    return p;
}

@addMethod(CR4Player)
function CjFlyStart() {
    var tmpl : CEntityTemplate;
    var fov : float;
    w3sFlyPos = theCamera.GetCameraPosition();
    w3sFlyRot = theCamera.GetCameraRotation();
    w3sFlyRot.Roll = 0;
    // GetCameraRotation reports pitch in 0..360 (338 = 22 down) - normalized, else the clamp points to the sky
    w3sFlyRot.Pitch = AngleNormalize180(w3sFlyRot.Pitch);
    w3sFlyIn = Vector(0, 0, 0, 1);
    w3sFlyOn = true;
    w3sFlyHome = GetWorldPosition();
    w3sFlyHomeRot = GetWorldRotation();
    w3sFlyAway = false;
    w3sFlyLast = w3sFlyPos;
    w3sFlyLastRot = w3sFlyRot;
    w3sFlyGoal = w3sFlyRot;
    fov = theCamera.GetFov();
    tmpl = (CEntityTemplate)LoadResource("gameplay\poster\poster_camera.w2ent", true);
    if (tmpl) {
        w3sFlyCam = (CStaticCamera)theGame.CreateEntity(tmpl, CjFlyEntityPos(), CjFlyEntityRot());
    }
    if (w3sFlyCam) {
        w3sFlyCam.activationDuration = 0;
        w3sFlyCam.deactivationDuration = 0;
        w3sFlyCam.fadeStartDuration = 0;
        w3sFlyCam.fadeEndDuration = 0;
        w3sFlyCam.SetFov(fov);
        w3sFlyCam.Run();
    } else {
        CjOut("camera fallback: no camera entity, debug free camera");
        w3sFlyFree = true;
        theGame.EnableFreeCamera(true);
        theGame.MoveFreeCamera(w3sFlyPos, w3sFlyRot);
    }
    RemoveTimer('CjFlyTick');
    AddTimer('CjFlyTick', 0.0, true);
    CjFlyFollow();                                 // at once: a later first jump blacked the screen out
    CjFlyReport();
}

@addMethod(CR4Player)
function CjFlyStop() {
    RemoveTimer('CjFlyTick');
    if (w3sFlyAway) {
        BreakAttachment();
        TeleportWithRotation(w3sFlyHome, w3sFlyHomeRot);
        CjFlyGhost(false);
        w3sFlyAway = false;
    }
    if (w3sFlyCam) {
        w3sFlyCam.Stop();
        w3sFlyCam.Destroy();
        w3sFlyCam = NULL;
    }
    if (w3sFlyFree) {
        // left on, the game could not be closed any more
        theGame.EnableFreeCamera(false);
        w3sFlyFree = false;
    }
    w3sFlyOn = false;
}

@addMethod(CR4Player)
function CjFlyInput(fwd : float, right : float, up : float, fast : float, dyaw : float, dpitch : float) {
    w3sFlyIn = Vector(fwd, right, up, fast);
    w3sFlyInTime = EngineTimeToFloat(theGame.GetEngineTime());
    // only the goal: the mouse's steps come in the app's rhythm, not the game's frames - turned at once they came
    // two in one frame and none in the next (06.10.: micro stutter while looking); the tick glides there
    w3sFlyGoal.Yaw = AngleNormalize(w3sFlyGoal.Yaw - dyaw);
    w3sFlyGoal.Pitch = ClampF(w3sFlyGoal.Pitch - dpitch, -89, 89);
}

@addMethod(CR4Player)
function CjFlyAxes(out f : Vector, out r : Vector, out u : Vector) {
    f = VecFromHeading(w3sFlyRot.Yaw) * CosF(Deg2Rad(w3sFlyRot.Pitch));
    f.Z = SinF(Deg2Rad(w3sFlyRot.Pitch));
    r = VecFromHeading(w3sFlyRot.Yaw - 90);
    u = VecCross(r, f);
}

@addMethod(CR4Player)
timer function CjFlyTick(dt : float, id : int) {
    var f, r, u, move : Vector;
    var k, d : float;
    // the game must never pause in the editor: losing the focus (to the editor's panel) makes it open its pause
    // menu, which the NG scripts skip while this fact is set (as for timed dialogue choices). Renewed every frame
    // with a short life: a save made while editing cannot keep the pause menu off.
    FactsSet("nge_pause_menu_disabled", 1, 10);
    CjFreezeDue();
    CjGhostDue();
    if (w3sFlyAway) {                               // whatever started a line of his while he rides along: cut
        StopAllVoicesets(false);
    }
    // the player's states put their own input context back (remaster: clicks made Geralt fight) - ours again
    if (theInput.GetContext() != 'EMPTY_CONTEXT') {
        CjOut("context|" + NameToString(theInput.GetContext()));
        theInput.SetContext('EMPTY_CONTEXT');
    }
    if (EngineTimeToFloat(theGame.GetEngineTime()) - w3sFlyInTime > 0.25) {
        w3sFlyIn = Vector(0, 0, 0, 1);
    }
    // the view glides to where the mouse turned it (about 90 % in 80 ms): smooth whatever rhythm the input has
    k = 1 - ExpF(-28.0 * dt);
    d = AngleNormalize180(w3sFlyGoal.Yaw - w3sFlyRot.Yaw);
    if (AbsF(d) < 0.01) {
        w3sFlyRot.Yaw = w3sFlyGoal.Yaw;
    } else {
        w3sFlyRot.Yaw = AngleNormalize(w3sFlyRot.Yaw + d * k);
    }
    d = w3sFlyGoal.Pitch - w3sFlyRot.Pitch;
    if (AbsF(d) < 0.01) {
        w3sFlyRot.Pitch = w3sFlyGoal.Pitch;
    } else {
        w3sFlyRot.Pitch = w3sFlyRot.Pitch + d * k;
    }
    CjFlyAxes(f, r, u);
    move = f * w3sFlyIn.X + r * w3sFlyIn.Y;
    move.Z += w3sFlyIn.Z;
    w3sFlyPos = w3sFlyPos + move * (4.0 * w3sFlyIn.W * dt);
    w3sFlyPos.W = 1;
    if (w3sFlyPos.X == w3sFlyLast.X && w3sFlyPos.Y == w3sFlyLast.Y && w3sFlyPos.Z == w3sFlyLast.Z
            && w3sFlyRot.Yaw == w3sFlyLastRot.Yaw && w3sFlyRot.Pitch == w3sFlyLastRot.Pitch) {
        return;
    }
    w3sFlyLast = w3sFlyPos;
    w3sFlyLastRot = w3sFlyRot;
    if (w3sFlyCam) {
        w3sFlyCam.TeleportWithRotation(CjFlyEntityPos(), CjFlyEntityRot());
    } else {
        theGame.MoveFreeCamera(w3sFlyPos, w3sFlyRot);
    }
    CjLampFollow(w3sFlyPos, w3sFlyRot);
    CjFlyReport();
    CjFlyFollow();
}

// Geralt while he rides along: only there for the streaming - unseen, untouchable, not animated, unnoticed by NPCs
@addMethod(CR4Player)
function CjFlyGhost(on : bool) {
    var anim : CAnimatedComponent;
    var none : array<EInputActionBlock>;
    SetHideInGame(on);
    EnableCollisions(!on);
    SetGameplayVisibility(!on);
    // silent and idle too (06.10.: the hidden Geralt still spoke his lines): no voice of his, none of his actions
    // (interactions, medallion, signs ...) - the game's own locks, the menus stay
    SetCanPlaySpecificVoiceset(!on);
    BlockAllActions('CjGhost', on, none, true);
    if (on) {
        StopAllVoicesets(true);
        SetImmortalityMode(AIM_Invulnerable, AIC_Default);
    } else {
        SetImmortalityMode(AIM_None, AIC_Default);
    }
    anim = GetRootAnimatedComponent();
    if (anim) {
        if (on) {
            anim.FreezePose();
        } else {
            anim.UnfreezePose();
        }
    }
}

@addMethod(CR4Player)
function CjFlySetHome(p : Vector) {
    w3sFlyHome = p;
}

// the game streams the world around the player: far from him, the camera would see an empty world - so from the
// editor's start he rides along with it, a ghost (CjFlyGhost), attached to the camera entity (as an elevator carries
// him: no teleports - a player teleport blacks the screen out while the world loads)
@addMethod(CR4Player)
function CjFlyFollow() {
    if (w3sFlyAway || !w3sFlyCam) {
        return;
    }
    w3sFlyAway = true;
    CjFlyGhost(true);
    CreateAttachment(w3sFlyCam, '', Vector(0, 0, -1.5));
}

exec function cj_cam(fwd : float, right : float, up : float, fast : float, dyaw : float, dpitch : float) {
    if (thePlayer.w3sFlyOn) {
        thePlayer.CjFlyInput(fwd, right, up, fast, dyaw, dpitch);
    }
}

// the game got the focus back while the editor is on: the engine paused the sound on focus loss and resumes it when
// the pause menu closes - a menu the editor keeps shut (nge_pause_menu_disabled)
exec function cj_sound_resume() {
    theSound.SoundEvent("system_resume");
}

// the suite's 'Sound: off', or another program in front: the game's sound paused (the pause menu's event)
exec function cj_sound_pause() {
    theSound.SoundEvent("system_pause");
}

exec function cj_cam_sync() {
    if (thePlayer.w3sFlyOn) {
        thePlayer.CjFlyReport();
    }
}

// Jump (quest board, object lists): the camera to 3.5 m in front of a thing, looking at it from a little above
@addMethod(CR4Player)
function CjFlyTo(x : float, y : float, z : float, yaw : float) {
    var target, d : Vector;
    if (!w3sFlyOn) {
        return;
    }
    target = Vector(x, y, z + 1.2, 1);
    w3sFlyPos = target + VecFromHeading(yaw) * 3.5;
    w3sFlyPos.Z = z + 2.2;
    w3sFlyPos.W = 1;
    d = target - w3sFlyPos;
    w3sFlyRot.Yaw = VecHeading(d);
    w3sFlyRot.Pitch = -12;
    w3sFlyRot.Roll = 0;
    w3sFlyGoal = w3sFlyRot;                         // a jump: there at once, no glide
    CjFlyReport();
}

exec function cj_cam_to(x : float, y : float, z : float, yaw : float) {
    thePlayer.CjFlyTo(x, y, z, yaw);
}

// a talk's own camera: the editor camera exactly there (to look through it)
@addMethod(CR4Player)
function CjFlySet(x : float, y : float, z : float, yaw : float, pitch : float) {
    if (!w3sFlyOn) {
        return;
    }
    w3sFlyPos = Vector(x, y, z, 1);
    w3sFlyRot.Yaw = yaw;
    w3sFlyRot.Pitch = pitch;
    w3sFlyRot.Roll = 0;
    w3sFlyGoal = w3sFlyRot;
    CjFlyReport();
}

exec function cj_cam_set(x : float, y : float, z : float, yaw : float, pitch : float) {
    thePlayer.CjFlySet(x, y, z, yaw, pitch);
}
