// conjunction: a person of a quest shows the name its author gave them (above them, when Geralt looks at them). The
// quest's DLC strings hold it under the key cj_name_<the person's tag> (build.people_names); everyone else keeps
// the game's own name. No game script is replaced: the HUD's name update is wrapped.
// The wrapper only passes the name on (an early return inside a wrapped void method crashed the game at start).

function CjOwnName(fallback : string) : string {
    var target : CGameplayEntity;
    var tags : array< name >;
    var own : string;
    var i : int;
    target = thePlayer.GetDisplayTarget();
    if (target) {
        tags = target.GetTags();
        for (i = 0; i < tags.Size(); i += 1) {
            own = GetLocStringByKeyExt(StrLower("cj_name_" + NameToString(tags[i])));
            if (own != "" && own != "#") {
                return own;
            }
        }
    }
    return fallback;
}

@wrapMethod(CR4HudModuleEnemyFocus)
function UpdateName(enemyName : string) {
    wrappedMethod(CjOwnName(enemyName));
}
