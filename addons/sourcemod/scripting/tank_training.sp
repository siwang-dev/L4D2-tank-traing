#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>
#include <multicolors>
#undef REQUIRE_PLUGIN
#include <l4d2_boss_percents>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.1.2"
#define MAX_IRON_PROPS 2048
// Forklift model path.
#define FORKLIFT_MODEL "models/props/cs_assault/forklift.mdl"

// Stores tracked hittable state.
enum struct IronData {
    int entityIndex;
    char modelName[128];
    float originalPos[3];
    float originalAng[3];
    bool isForklift;
    bool isActive;
    // Extra forklift properties.
    float originalMins[3];
    float originalMaxs[3];
    int originalSpawnFlags;
    int originalCollisionGroup;
    int originalSolidType;
    float originalMass;
    char originalTargetName[64];
    char originalParentName[64];
}

enum struct HittableResetProp {
    char className[64];
    char modelName[128];
    float origin[3];
    float angles[3];
    int spawnFlags;
    int renderColor;
    float fadeMinDist;
    float fadeMaxDist;
    int hammerId;
    char targetName[64];
    bool isForklift;
}

// Global state.
ConVar g_cvTankHealth;
ConVar g_cvDisablePlugin;
ConVar g_cvLockTankControl;

IronData g_IronProps[MAX_IRON_PROPS];
int g_IronCount = 0;

ArrayList g_hTankPropsHitList;
StringMap g_smHittableResetProp;
bool g_bTankSpawned = false;

int g_iPendingTank[MAXPLAYERS + 1];
bool g_bNoClip[MAXPLAYERS + 1];
bool g_bTankDied[MAXPLAYERS + 1];

int g_iDesiredTankOwnerUserId = 0;
int g_iTankOwnerRetries = 0;

enum TankSpawnMode
{
    TankSpawn_Soul = 0,
    TankSpawn_Flow
};

public Plugin myinfo = 
{
    name = "Tank Hittable Reset",
    author = "Siwang(死亡中心最菜传说)and ai",
    description = "training GOGOGO",
    version = "2.2.2",    //
    url = ""
};

public void OnPluginStart()
{
    LoadTranslations("tank_training.phrases");

    g_hTankPropsHitList = new ArrayList();
    g_smHittableResetProp = new StringMap();

    g_cvTankHealth = CreateConVar("sm_tankreset_health", "6000", "Tank health", FCVAR_NOTIFY, true, 1000.0);
    g_cvDisablePlugin = CreateConVar("sm_tankreset_disabled", "0", "Disable this plugin (1 = all features disabled)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvLockTankControl = CreateConVar("sm_tankreset_lock_control", "0", "Lock Tank control (1 = Tank frustration no longer increases)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    
    RegConsoleCmd("sm_tk", Command_TankMenu, "Open the Tank menu");
    RegConsoleCmd("sm_btank", Command_BecomeTank, "Become an infected class");
    RegConsoleCmd("sm_tnoclip", Command_NoClip, "Toggle noclip mode");
    RegConsoleCmd("sm_tlock", Command_TankControlLock, "Toggle Tank control lock");
    RegConsoleCmd("sm_forklift_info", Command_ForkliftInfo, "Print recorded forklift information");
    RegConsoleCmd("sm_forklift_resetpos", Command_ForkliftResetPos, "Reset all forklift positions");

    HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("tank_spawn", Event_TankSpawn);
    
    AutoExecConfig(true, "tank_reset_plugin");
    
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iPendingTank[i] = 0;
        g_bNoClip[i] = false;
        g_bTankDied[i] = false;
    }
    
    for (int i = 0; i < MAX_IRON_PROPS; i++) {
        g_IronProps[i].isActive = false;
        g_IronProps[i].entityIndex = -1;
        g_IronProps[i].isForklift = false;
    }
    
    PrintToServer("[TankReset] %T", "Plugin Loaded", LANG_SERVER, PLUGIN_VERSION);
}

public void OnMapStart()
{
    if (g_cvDisablePlugin.BoolValue)
        return;

    ClearHittableTracking();
    PrecacheForkliftAssets();
    CreateTimer(2.0, Timer_ScanIronProps);
    PrecacheSound("buttons/button14.wav", true);
}

public void OnMapEnd()
{
    ClearHittableTracking();
    g_bTankSpawned = false;
}

public void OnClientPutInServer(int client)
{
    g_iPendingTank[client] = 0;
    g_bNoClip[client] = false;
    g_bTankDied[client] = false;
}

public void OnClientDisconnect(int client)
{
    g_iPendingTank[client] = 0;
    g_bNoClip[client] = false;
    g_bTankDied[client] = false;
}

// ==================== Core hittable scanning and recording ====================

public Action Timer_ScanIronProps(Handle timer)
{
    ScanForIronProps();
    return Plugin_Stop;
}

void ScanForIronProps()
{
    g_IronCount = 0;
    ClearIronData();
    
    int iEntCount = GetMaxEntities();
    char className[64];
    
    for (int i = MaxClients + 1; i < iEntCount; i++)
    {
        if (!IsValidEdict(i))
            continue;
            
        GetEdictClassname(i, className, sizeof(className));
        
        if (!IsTrackedHittableClass(className))
            continue;
            
        char modelName[128];
        GetEntPropString(i, Prop_Data, "m_ModelName", modelName, sizeof(modelName));
        
        bool isForklift = IsForkliftModel(modelName);
        
        // Fallback: forklifts are tracked as hittables even when they do not expose the glow property.
        if (!isForklift)
        {
            if (!HasEntProp(i, Prop_Send, "m_hasTankGlow"))
                continue;
                
            bool bHasTankGlow = (GetEntProp(i, Prop_Send, "m_hasTankGlow", 1) == 1);
            if (!bHasTankGlow)
                continue;
        }
        
        AddIronProp(i, modelName, isForklift);
    }
    
    PrintToServer("[TankReset] %T", "Scan Complete", LANG_SERVER, g_IronCount, CountForklifts());
}

bool IsForkliftModel(const char[] modelName)
{
    return StrEqual(modelName, FORKLIFT_MODEL, false) || 
           StrContains(modelName, "forklift", false) != -1;
}

int CountForklifts()
{
    int count = 0;
    for (int i = 0; i < g_IronCount; i++)
    {
        if (g_IronProps[i].isForklift)
            count++;
    }
    return count;
}

void PrintForkliftInfo()
{
    for (int i = 0; i < g_IronCount; i++)
    {
        if (!g_IronProps[i].isActive || !g_IronProps[i].isForklift)
            continue;

        PrintToServer("[TankReset] Forklift #%d entity=%d model=%s pos=%.1f %.1f %.1f ang=%.1f %.1f %.1f",
            i,
            g_IronProps[i].entityIndex,
            g_IronProps[i].modelName,
            g_IronProps[i].originalPos[0],
            g_IronProps[i].originalPos[1],
            g_IronProps[i].originalPos[2],
            g_IronProps[i].originalAng[0],
            g_IronProps[i].originalAng[1],
            g_IronProps[i].originalAng[2]);
    }
}

bool ResetForkliftPosition(int index)
{
    if (index < 0 || index >= g_IronCount || !g_IronProps[index].isActive || !g_IronProps[index].isForklift)
        return false;

    int entity = g_IronProps[index].entityIndex;
    if (entity == -1 || !IsValidEntity(entity))
    {
        entity = SpawnForkliftPhysics(g_IronProps[index].originalPos, g_IronProps[index].originalAng, g_IronProps[index].modelName);
        if (entity == -1)
            return false;

        g_IronProps[index].entityIndex = entity;
    }
    else
    {
        TeleportEntity(entity, g_IronProps[index].originalPos, g_IronProps[index].originalAng, NULL_VECTOR);
        SetEntityMoveType(entity, MOVETYPE_VPHYSICS);
    }

    if (HasEntProp(entity, Prop_Send, "m_hasTankGlow"))
        SetEntProp(entity, Prop_Send, "m_hasTankGlow", 1, 1);

    RequestFrame(OnNextFrame_SaveHittable, EntIndexToEntRef(entity));
    return true;
}

void AddIronProp(int entity, const char[] modelName, bool isForklift)
{
    if (g_IronCount >= MAX_IRON_PROPS) return;
    
    int index = g_IronCount++;
    g_IronProps[index].entityIndex = entity;
    strcopy(g_IronProps[index].modelName, 128, modelName);
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", g_IronProps[index].originalPos);
    GetEntPropVector(entity, Prop_Send, "m_angRotation", g_IronProps[index].originalAng);
    g_IronProps[index].isForklift = isForklift;
    g_IronProps[index].isActive = true;

    RequestFrame(OnNextFrame_SaveHittable, EntIndexToEntRef(entity));
}

void ClearIronData()
{
    for (int i = 0; i < MAX_IRON_PROPS; i++) {
        g_IronProps[i].isActive = false;
        g_IronProps[i].entityIndex = -1;
        g_IronProps[i].modelName[0] = '\0';
        g_IronProps[i].isForklift = false;
        g_IronProps[i].originalTargetName[0] = '\0';
        g_IronProps[i].originalParentName[0] = '\0';
        g_IronProps[i].originalSpawnFlags = 256;
        g_IronProps[i].originalCollisionGroup = 0;
        g_IronProps[i].originalSolidType = 6;
        g_IronProps[i].originalMass = 0.0;
    }
}

// ==================== Manual hittable reset ====================

void ResetAllIronProps()
{
    int resetCount = ResetAllHittable();
    PrintToServer("[TankReset] %T", "Reset Hittables Log", LANG_SERVER, resetCount);
    EmitSoundToAll("buttons/button14.wav", SOUND_FROM_PLAYER, SNDCHAN_AUTO, SNDLEVEL_NORMAL);
    return;
}

int ResetAllHittable()
{
    int count = 0;

    for (int i = 0; i < g_hTankPropsHitList.Length; i++)
    {
        int oldRef = g_hTankPropsHitList.Get(i);
        char refKey[32];
        IntToString(oldRef, refKey, sizeof(refKey));

        HittableResetProp prop;
        if (!g_smHittableResetProp.GetArray(refKey, prop, sizeof(prop)))
            continue;

        int entity = EntRefToEntIndex(oldRef);
        if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity))
        {
            entity = RecreateHittable(prop);
            if (entity == -1)
                continue;
        }

        RestoreHittableState(entity, prop);

        int newRef = EntIndexToEntRef(entity);
        if (newRef != oldRef)
        {
            g_hTankPropsHitList.Set(i, newRef);

            char newRefKey[32];
            IntToString(newRef, newRefKey, sizeof(newRefKey));
            g_smHittableResetProp.SetArray(newRefKey, prop, sizeof(prop), true);
            RequestFrame(OnNextFrame_SaveHittable, newRef);
        }

        count++;
    }

    g_hTankPropsHitList.Clear();
    return count;
}

int RecreateHittable(const HittableResetProp prop)
{
    int entity = -1;

    if (prop.isForklift)
    {
        entity = SpawnForkliftPhysics(prop.origin, prop.angles, prop.modelName);
    }
    else
    {
        entity = CreateEntityByName(prop.className[0] != '\0' ? prop.className : "prop_physics");
        if (entity == -1)
            return -1;

        if (prop.modelName[0] != '\0')
            DispatchKeyValue(entity, "model", prop.modelName);

        char spawnFlags[32];
        IntToString(prop.spawnFlags, spawnFlags, sizeof(spawnFlags));
        DispatchKeyValue(entity, "spawnflags", spawnFlags);
        DispatchSpawn(entity);
        ActivateEntity(entity);
    }

    return entity;
}

void RestoreHittableState(int entity, const HittableResetProp prop)
{
    TeleportEntity(entity, prop.origin, prop.angles, NULL_VECTOR);

    if (HasEntProp(entity, Prop_Send, "m_hasTankGlow"))
        SetEntProp(entity, Prop_Send, "m_hasTankGlow", 1, 1);
    if (HasEntProp(entity, Prop_Data, "m_spawnflags"))
        SetEntProp(entity, Prop_Data, "m_spawnflags", prop.spawnFlags);
    if (HasEntProp(entity, Prop_Send, "m_clrRender"))
        SetEntProp(entity, Prop_Send, "m_clrRender", prop.renderColor);
    if (HasEntProp(entity, Prop_Data, "m_fadeMinDist"))
        SetEntPropFloat(entity, Prop_Data, "m_fadeMinDist", prop.fadeMinDist);
    if (HasEntProp(entity, Prop_Data, "m_fadeMaxDist"))
        SetEntPropFloat(entity, Prop_Data, "m_fadeMaxDist", prop.fadeMaxDist);
    if (HasEntProp(entity, Prop_Data, "m_iHammerID"))
        SetEntProp(entity, Prop_Data, "m_iHammerID", prop.hammerId);
    if (prop.targetName[0] != '\0' && HasEntProp(entity, Prop_Data, "m_iName"))
        SetEntPropString(entity, Prop_Data, "m_iName", prop.targetName);

    SetEntityMoveType(entity, MOVETYPE_VPHYSICS);
}

public void OnEntityCreated(int entity, const char[] classname)
{
    if (IsTrackedHittableClass(classname))
        RequestFrame(OnNextFrame_SaveHittable, EntIndexToEntRef(entity));
}

public void OnNextFrame_SaveHittable(any entityRef)
{
    int entity = EntRefToEntIndex(entityRef);
    if (entity == INVALID_ENT_REFERENCE || !IsValidEntity(entity) || !IsTankPropEntity(entity))
        return;

    SDKHook(entity, SDKHook_OnTakeDamage, HittableOnTakeDamage);

    HittableResetProp prop;
    GetEdictClassname(entity, prop.className, sizeof(prop.className));
    GetEntPropString(entity, Prop_Data, "m_ModelName", prop.modelName, sizeof(prop.modelName));
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", prop.origin);
    GetEntPropVector(entity, Prop_Send, "m_angRotation", prop.angles);

    prop.isForklift = IsForkliftModel(prop.modelName);

    if (HasEntProp(entity, Prop_Data, "m_spawnflags"))
        prop.spawnFlags = GetEntProp(entity, Prop_Data, "m_spawnflags");
    if (HasEntProp(entity, Prop_Send, "m_clrRender"))
        prop.renderColor = GetEntProp(entity, Prop_Send, "m_clrRender");
    if (HasEntProp(entity, Prop_Data, "m_fadeMinDist"))
        prop.fadeMinDist = GetEntPropFloat(entity, Prop_Data, "m_fadeMinDist");
    if (HasEntProp(entity, Prop_Data, "m_fadeMaxDist"))
        prop.fadeMaxDist = GetEntPropFloat(entity, Prop_Data, "m_fadeMaxDist");
    if (HasEntProp(entity, Prop_Data, "m_iHammerID"))
        prop.hammerId = GetEntProp(entity, Prop_Data, "m_iHammerID");
    if (HasEntProp(entity, Prop_Data, "m_iName"))
        GetEntPropString(entity, Prop_Data, "m_iName", prop.targetName, sizeof(prop.targetName));

    char refKey[32];
    IntToString(entityRef, refKey, sizeof(refKey));
    g_smHittableResetProp.SetArray(refKey, prop, sizeof(prop), true);
}

public Action HittableOnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_bTankSpawned || victim <= MaxClients || !IsValidEntity(victim))
        return Plugin_Continue;

    if (!IsValidAliveTank(attacker) && !IsValidAliveTank(inflictor))
        return Plugin_Continue;

    int entityRef = EntIndexToEntRef(victim);
    if (g_hTankPropsHitList.FindValue(entityRef) == -1)
        g_hTankPropsHitList.Push(entityRef);

    return Plugin_Continue;
}

bool IsTrackedHittableClass(const char[] classname)
{
    return StrContains(classname, "prop_physics", false) == 0
        || StrContains(classname, "prop_car_alarm", false) == 0;
}

bool IsTankPropEntity(int entity)
{
    if (!IsValidEntity(entity))
        return false;

    char className[64], modelName[128];
    GetEdictClassname(entity, className, sizeof(className));
    GetEntPropString(entity, Prop_Data, "m_ModelName", modelName, sizeof(modelName));

    if (IsForkliftModel(modelName))
        return true;

    return IsTrackedHittableClass(className)
        && HasEntProp(entity, Prop_Send, "m_hasTankGlow")
        && GetEntProp(entity, Prop_Send, "m_hasTankGlow", 1) == 1;
}

bool IsValidAliveTank(int client)
{
    return client > 0 && client <= MaxClients
        && IsClientInGame(client)
        && GetClientTeam(client) == 3
        && IsPlayerAlive(client)
        && IsPlayerTank(client);
}

void ClearHittableTracking()
{
    if (g_hTankPropsHitList != null)
        g_hTankPropsHitList.Clear();
    if (g_smHittableResetProp != null)
        g_smHittableResetProp.Clear();
}

void PrecacheForkliftAssets()
{
    if (!IsModelPrecached(FORKLIFT_MODEL))
    {
        PrecacheModel(FORKLIFT_MODEL, true);
        PrintToServer("[TankReset] %T", "Precached Forklift", LANG_SERVER, FORKLIFT_MODEL);
    }
}

// Spawn a physical forklift through prop_physics_override.
int SpawnForkliftPhysics(const float position[3], const float angles[3], const char[] modelName)
{
    int prop = CreateEntityByName("prop_physics_override");
    if (prop == -1)
    {
        PrintToServer("[TankReset] %T", "Create Physics Error", LANG_SERVER);
        return -1;
    }

    char actualModel[128];
    if (modelName[0] == '\0')
        strcopy(actualModel, sizeof(actualModel), FORKLIFT_MODEL);
    else
        strcopy(actualModel, sizeof(actualModel), modelName);

    if (!IsModelPrecached(actualModel))
    {
        PrecacheModel(actualModel, true);
    }

    // Match the physics spawn path used by l4d2_spawn_props.
    DispatchKeyValue(prop, "model", actualModel);
    DispatchKeyValue(prop, "targetname", "tankreset_forklift_physics");
    DispatchKeyValue(prop, "spawnflags", "256");
    
    // Spawn the entity.
    DispatchSpawn(prop);
    
    // Place it at the recorded origin.
    TeleportEntity(prop, position, angles, NULL_VECTOR);
    
    // Restore the physics behavior expected from the original hittable.
    SetEntProp(prop, Prop_Data, "m_CollisionGroup", 0);
    SetEntityMoveType(prop, MOVETYPE_VPHYSICS);
    
    PrintToServer("[TankReset] %T", "Spawned Forklift", LANG_SERVER, actualModel, prop);
    return prop;
}

void CopyVector3(const float original[3], float copy[3])
{
    for (int i = 0; i < 3; i++)
    {
        copy[i] = original[i];
    }
}

// ==================== Colored chat output ====================

void ReplyTranslated(int client, const char[] phrase)
{
    if (!IsValidClient(client))
        return;

    CReplyToCommand(client, "%t", phrase);
}

void PrintBecameInfected(int actor, const char[] displayName)
{
    CPrintToChatAll("%t", "Became Infected All", actor, displayName);
    CPrintToChat(actor, "%t", "Became Infected Self", displayName);
}

void PrintFeatureDisabled(int client)
{
    CPrintToChat(client, "%t", "Feature Disabled");
}

// ==================== Command handling ====================

public Action Command_TankMenu(int client, int args)
{
    if (g_cvDisablePlugin.BoolValue)
    {
        ReplyTranslated(client, "Plugin Disabled Menu Available");
    }

    ShowTankMenu(client);
    return Plugin_Handled;
}

public Action Command_BecomeTank(int client, int args)
{
    if (g_cvDisablePlugin.BoolValue)
    {
        ReplyTranslated(client, "Plugin Disabled");
        return Plugin_Handled;
    }
    
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    if (!IsVersusMode() && !IsCoopMode())
    {
        ReplyTranslated(client, "Mode Not Supported");
        return Plugin_Handled;
    }
    
    if (!IsPlayerAlive(client))
    {
        ReplyTranslated(client, "Need Alive");
        return Plugin_Handled;
    }
    
    if (IsPlayerTank(client))
    {
        ReplyTranslated(client, "Already Tank");
        return Plugin_Handled;
    }

    char zombieClass[32] = "tank";
    TankSpawnMode spawnMode = TankSpawn_Soul;
    if (args >= 1)
    {
        GetCmdArg(1, zombieClass, sizeof(zombieClass));
        if (!IsAllowedInfectedClass(zombieClass))
        {
            ReplyTranslated(client, "Invalid Class");
            return Plugin_Handled;
        }
    }

    if (args >= 2 && StrEqual(zombieClass, "tank", false))
    {
        char modeArg[16];
        GetCmdArg(2, modeArg, sizeof(modeArg));
        if (StrEqual(modeArg, "flow", false))
            spawnMode = TankSpawn_Flow;
    }
    
    g_bTankDied[client] = false;
    g_iPendingTank[client] = GetClientUserId(client);
    if (StrEqual(zombieClass, "tank", false))
    {
        g_iDesiredTankOwnerUserId = GetClientUserId(client);
        g_iTankOwnerRetries = 0;
    }
    
    if (BecomeInfected(client, zombieClass, spawnMode))
    {
        char displayName[32];
        GetInfectedDisplayName(zombieClass, displayName, sizeof(displayName));
        PrintBecameInfected(client, displayName);
    }
    else
    {
        g_iPendingTank[client] = 0;
        ReplyTranslated(client, "Become Failed");
    }
    
    return Plugin_Handled;
}

public Action Command_NoClip(int client, int args)
{
    if (g_cvDisablePlugin.BoolValue)
    {
        ReplyTranslated(client, "Plugin Disabled");
        return Plugin_Handled;
    }
    
    if (!IsValidClient(client))
        return Plugin_Handled;
    
    g_bNoClip[client] = !g_bNoClip[client];
    
    if (g_bNoClip[client])
    {
        SetEntityMoveType(client, MOVETYPE_NOCLIP);
        CPrintToChat(client, "%t", "Noclip Enabled");
    }
    else
    {
        SetEntityMoveType(client, MOVETYPE_WALK);
        CPrintToChat(client, "%t", "Noclip Disabled");
    }
    
    return Plugin_Handled;
}

public Action Command_TankControlLock(int client, int args)
{
    if (g_cvDisablePlugin.BoolValue)
    {
        ReplyTranslated(client, "Plugin Disabled");
        return Plugin_Handled;
    }

    bool enabled = !g_cvLockTankControl.BoolValue;
    g_cvLockTankControl.SetBool(enabled);
    CPrintToChatAll("%t", enabled ? "Tank Lock Enabled" : "Tank Lock Disabled");
    return Plugin_Handled;
}

public Action Command_ForkliftInfo(int client, int args)
{
    if (g_cvDisablePlugin.BoolValue)
    {
        ReplyTranslated(client, "Plugin Disabled");
        return Plugin_Handled;
    }

    PrintForkliftInfo();

    int count = 0;
    for (int i = 0; i < g_IronCount; i++)
    {
        if (g_IronProps[i].isActive && g_IronProps[i].isForklift)
            count++;
    }

    CPrintToChat(client, "%t", "Forklift Info Printed", count);
    return Plugin_Handled;
}

public Action Command_ForkliftResetPos(int client, int args)
{
    if (g_cvDisablePlugin.BoolValue)
    {
        ReplyTranslated(client, "Plugin Disabled");
        return Plugin_Handled;
    }

    int success = 0;
    int total = 0;

    for (int i = 0; i < g_IronCount; i++)
    {
        if (!g_IronProps[i].isActive || !g_IronProps[i].isForklift)
            continue;

        total++;
        if (ResetForkliftPosition(i))
            success++;
    }

    CPrintToChatAll("%t", "Forklift Reset", client, success, total);
    return Plugin_Handled;
}

int GetRealPlayerCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && !IsFakeClient(i))
        {
            count++;
        }
    }
    return count;
}

// ==================== Menu system ====================

void RedisplayTankMenu(int client)
{
    if (IsValidClient(client))
        RequestFrame(Frame_ShowTankMenu, GetClientUserId(client));
}

public void Frame_ShowTankMenu(any userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client))
        ShowTankMenu(client);
}


void ShowTankMenu(int client)
{
    Menu menu = new Menu(TankMenuHandler);
    
    bool disabled = g_cvDisablePlugin.BoolValue;
    
    if (disabled)
    {
        menu.SetTitle("%T", "Tank Menu Disabled Title", client);
    }
    else
    {
        menu.SetTitle("%T", "Tank Menu Title", client);
    }
    
    char disabledSuffix[32];
    FormatEx(disabledSuffix, sizeof(disabledSuffix), "%T", "Disabled Suffix", client);

    char forceItem[64];
    Format(forceItem, sizeof(forceItem), "%T%s", "Menu Force Start", client, disabled ? disabledSuffix : "");
    menu.AddItem("forcestart", forceItem, disabled ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    
    char resetItem[64];
    Format(resetItem, sizeof(resetItem), "%T%s", "Menu Reset Hittables", client, disabled ? disabledSuffix : "");
    menu.AddItem("reset", resetItem, disabled ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    
    char becomeItem[64];
    Format(becomeItem, sizeof(becomeItem), "%T%s", "Menu Become Infected", client, disabled ? disabledSuffix : "");
    menu.AddItem("become", becomeItem, disabled ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    
    char noclipItem[64];
    Format(noclipItem, sizeof(noclipItem), "%T%s", "Menu Noclip", client, disabled ? disabledSuffix : "");
    menu.AddItem("noclip", noclipItem, disabled ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

    char lockItem[64];
    char lockState[32];
    FormatEx(lockState, sizeof(lockState), "%T", g_cvLockTankControl.BoolValue ? "State On" : "State Off", client);
    Format(lockItem, sizeof(lockItem), "%T%s", "Menu Lock Control", client, lockState, disabled ? disabledSuffix : "");
    menu.AddItem("lockcontrol", lockItem, disabled ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);

    char teleportItem[64];
    Format(teleportItem, sizeof(teleportItem), "%T%s", "Menu Teleport Survivor", client, disabled ? disabledSuffix : "");
    menu.AddItem("tpsurvivor", teleportItem, disabled ? ITEMDRAW_DISABLED : ITEMDRAW_DEFAULT);
    
    char statusItem[64];
    char status[64];
    FormatEx(status, sizeof(status), "%T", disabled ? "Status Disabled" : "Status Enabled", client);
    Format(statusItem, sizeof(statusItem), "%T", "Menu Status", client, status);
    menu.AddItem("status", statusItem, ITEMDRAW_DISABLED);
    
    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public Action Timer_DoReset(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    // Perform reset logic on next tick to avoid interfering with menu lifecycle.
    ResetAllIronProps();
    CPrintToChatAll("%t", "Reset All Hittables", client);
    CPrintToChat(client, "%t", "Reset Hittables Count", g_IronCount);
    return Plugin_Stop;
}

public Action Timer_ReopenTankMenu(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client))
        ShowTankMenu(client);
    return Plugin_Stop;
}

public int TankMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            
            if (StrEqual(info, "forcestart"))
            {
                if (g_cvDisablePlugin.BoolValue)
                {
                    PrintFeatureDisabled(param1);
                    RedisplayTankMenu(param1);
                    delete menu;
                    return 0;
                }

                ForceStartGame(param1);
                ShowTankMenu(param1);
            }
            else if (StrEqual(info, "reset"))
            {
                if (g_cvDisablePlugin.BoolValue)
                {
                    PrintFeatureDisabled(param1);
                    RedisplayTankMenu(param1);
                    delete menu;
                    return 0;
                }

                // Delete current menu instance and schedule reset + reopen via timers.
                delete menu;
                // Small delay to let the command handler finish, then perform reset.
                CreateTimer(0.01, Timer_DoReset, GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
                // Reopen menu after entities settle (longer delay).
                CreateTimer(0.5, Timer_ReopenTankMenu, GetClientUserId(param1), TIMER_FLAG_NO_MAPCHANGE);
                return 0;
            }
            else if (StrEqual(info, "become"))
            {
                if (g_cvDisablePlugin.BoolValue)
                {
                    PrintFeatureDisabled(param1);
                    RedisplayTankMenu(param1);
                    delete menu;
                    return 0;
                }
                
                ShowInfectedMenu(param1);
            }
            else if (StrEqual(info, "noclip"))
            {
                if (g_cvDisablePlugin.BoolValue)
                {
                    PrintFeatureDisabled(param1);
                    RedisplayTankMenu(param1);
                    delete menu;
                    return 0;
                }
                
                FakeClientCommand(param1, "sm_tnoclip");
                RedisplayTankMenu(param1);
            }
            else if (StrEqual(info, "tpsurvivor"))
            {
                if (g_cvDisablePlugin.BoolValue)
                {
                    PrintFeatureDisabled(param1);
                    RedisplayTankMenu(param1);
                    delete menu;
                    return 0;
                }

                ShowSurvivorTeleportMenu(param1);
            }
            else if (StrEqual(info, "lockcontrol"))
            {
                if (g_cvDisablePlugin.BoolValue)
                {
                    PrintFeatureDisabled(param1);
                    RedisplayTankMenu(param1);
                    return 0;
                }

                FakeClientCommand(param1, "sm_tlock");
                RedisplayTankMenu(param1);
            }
            else if (StrEqual(info, "status"))
            {
                RedisplayTankMenu(param1);
            }
        }
        case MenuAction_End: delete menu;
    }
    return 0;
}

void ShowInfectedMenu(int client)
{
    Menu menu = new Menu(InfectedMenuHandler);
    menu.SetTitle("%T", "Infected Menu Title", client);
    menu.AddItem("tank", "Tank");
    menu.AddItem("hunter", "Hunter");
    menu.AddItem("jockey", "Jockey");
    menu.AddItem("smoker", "Smoker");
    menu.AddItem("charger", "Charger");
    menu.AddItem("boomer", "Boomer");
    menu.AddItem("spitter", "Spitter");
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int InfectedMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            if (StrEqual(info, "tank", false))
            {
                ShowTankSpawnMenu(param1);
            }
            else
            {
                FakeClientCommand(param1, "sm_btank %s", info);
                ShowTankMenu(param1);
            }
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                ShowTankMenu(param1);
            }
        }
        case MenuAction_End: delete menu;
    }
    return 0;
}

void ShowTankSpawnMenu(int client)
{
    Menu menu = new Menu(TankSpawnMenuHandler);
    menu.SetTitle("%T", "Tank Spawn Menu Title", client);

    char item[96];
    FormatEx(item, sizeof(item), "%T", "Tank Spawn Soul", client);
    menu.AddItem("soul", item);

    int percent = GetStoredTankPercentSafe();
    if (percent > 0)
        FormatEx(item, sizeof(item), "%T", "Tank Spawn Flow Percent", client, percent);
    else
        FormatEx(item, sizeof(item), "%T", "Tank Spawn Flow", client);

    menu.AddItem("flow", item, percent > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int TankSpawnMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));
            FakeClientCommand(param1, "sm_btank tank %s", info);
            ShowTankMenu(param1);
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                ShowInfectedMenu(param1);
            }
        }
        case MenuAction_End: delete menu;
    }
    return 0;
}

void ShowSurvivorTeleportMenu(int client)
{
    Menu menu = new Menu(SurvivorTeleportMenuHandler);
    menu.SetTitle("%T", "Survivor Teleport Menu Title", client);

    char item[64];
    FormatEx(item, sizeof(item), "%T", "All Survivors", client);
    menu.AddItem("all", item);

    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
            continue;

        char userid[16];
        char name[64];
        IntToString(GetClientUserId(i), userid, sizeof(userid));
        Format(name, sizeof(name), "%N", i);
        menu.AddItem(userid, name);
        count++;
    }

    if (count == 0)
    {
        FormatEx(item, sizeof(item), "%T", "No Survivors Available", client);
        menu.AddItem("none", item, ITEMDRAW_DISABLED);
    }

    menu.ExitBackButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int SurvivorTeleportMenuHandler(Menu menu, MenuAction action, int param1, int param2)
{
    switch (action)
    {
        case MenuAction_Select:
        {
            char info[32];
            menu.GetItem(param2, info, sizeof(info));

            float pos[3];
            if (!GetClientAimPosition(param1, pos))
            {
                CPrintToChat(param1, "%t", "No Cursor Position");
                ShowSurvivorTeleportMenu(param1);
                return 0;
            }
            pos[2] += 5.0;

            if (StrEqual(info, "all"))
            {
                int count = TeleportAllSurvivors(pos);
                CPrintToChatAll("%t", "Teleported All Survivors", param1, count);
                ShowTankMenu(param1);
                return 0;
            }

            int target = GetClientOfUserId(StringToInt(info));
            if (!IsValidClient(target) || GetClientTeam(target) != 2 || !IsPlayerAlive(target))
            {
                CPrintToChat(param1, "%t", "Target Survivor Unavailable");
                ShowSurvivorTeleportMenu(param1);
                return 0;
            }
            TeleportEntity(target, pos, NULL_VECTOR, NULL_VECTOR);
            CPrintToChatAll("%t", "Teleported Survivor", param1, target);
            ShowTankMenu(param1);
        }
        case MenuAction_Cancel:
        {
            if (param2 == MenuCancel_ExitBack)
            {
                ShowTankMenu(param1);
            }
        }
        case MenuAction_End: delete menu;
    }
    return 0;
}

int TeleportAllSurvivors(const float pos[3])
{
    int count = 0;
    float targetPos[3];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
            continue;

        CopyVector3(pos, targetPos);
        targetPos[0] += float(count % 3) * 16.0;
        targetPos[1] += float(count / 3) * 16.0;
        TeleportEntity(i, targetPos, NULL_VECTOR, NULL_VECTOR);
        count++;
    }

    return count;
}

// ==================== Become infected support ====================

bool BecomeInfected(int client, const char[] zombieClass, TankSpawnMode spawnMode = TankSpawn_Soul)
{
    if (!IsValidClient(client) || !IsPlayerAlive(client) || !IsAllowedInfectedClass(zombieClass))
        return false;
    
    return BecomeInfectedDirect(client, zombieClass, spawnMode);
}

bool BecomeInfectedDirect(int client, const char[] zombieClass, TankSpawnMode spawnMode)
{
    if (StrEqual(zombieClass, "tank", false) && spawnMode == TankSpawn_Flow)
    {
        return SpawnTankAtStoredFlow(client);
    }

    // Continue with normal z_spawn path if not handling flow-spawn.

    int flags = GetCommandFlags("z_spawn");
    SetCommandFlags("z_spawn", flags & ~FCVAR_CHEAT);
    
    char cmd[256];
    Format(cmd, sizeof(cmd), "z_spawn %s %d", zombieClass, GetClientUserId(client));
    FakeClientCommand(client, cmd);
    
    SetCommandFlags("z_spawn", flags);
    
    g_iPendingTank[client] = GetClientUserId(client);
    
    if (StrEqual(zombieClass, "tank", false))
    {
        CreateTimer(0.5, SetTankHealthTimer, GetClientUserId(client));
        CreateTimer(0.4, Timer_EnsureTankOwner, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }
    
    return true;
}

bool SpawnTankAtStoredFlow(int client)
{
    if (GetFeatureStatus(FeatureType_Native, "L4D2_SpawnTank") != FeatureStatus_Available)
        return false;

    int percent = GetStoredTankPercentSafe();
    if (percent <= 0)
        return false;

    float pos[3], ang[3];
    if (!FindTankFlowSpawnPosition(percent, pos, ang))
        return false;

    int tank = L4D2_SpawnTank(pos, ang);
    if (tank <= 0)
        return false;

    g_iPendingTank[client] = GetClientUserId(client);
    g_iDesiredTankOwnerUserId = GetClientUserId(client);
    g_iTankOwnerRetries = 0;
    g_bTankSpawned = true;

    PrepareClientForTankReplace(client);
    if (tank != client && GetFeatureStatus(FeatureType_Native, "L4D_ReplaceTank") == FeatureStatus_Available)
    {
        L4D_ReplaceTank(tank, client);
    }

    CreateTimer(0.5, SetTankHealthTimer, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    CreateTimer(0.4, Timer_EnsureTankOwner, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    return true;
}

int GetStoredTankPercentSafe()
{
    if (GetFeatureStatus(FeatureType_Native, "GetStoredTankPercent") != FeatureStatus_Available)
        return -1;

    return GetStoredTankPercent();
}

bool FindTankFlowSpawnPosition(int percent, float pos[3], float ang[3])
{
    if (GetFeatureStatus(FeatureType_Native, "L4D_GetAllNavAreas") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "L4D_GetNavAreaCenter") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetTerrorNavAreaFlow") != FeatureStatus_Available
        || GetFeatureStatus(FeatureType_Native, "L4D2Direct_GetMapMaxFlowDistance") != FeatureStatus_Available)
    {
        return false;
    }

    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlow <= 0.0)
        return false;

    float targetFlow = maxFlow * (float(percent) / 100.0);
    ArrayList areas = new ArrayList();
    L4D_GetAllNavAreas(areas);

    if (areas.Length == 0)
    {
        delete areas;
        return false;
    }

    Address bestArea = Address_Null;
    float bestDelta = maxFlow + 1.0;

    for (int i = 0; i < areas.Length; i++)
    {
        Address area = view_as<Address>(areas.Get(i));
        if (area == Address_Null)
            continue;

        float flow = L4D2Direct_GetTerrorNavAreaFlow(area);
        float delta = FloatAbs(flow - targetFlow);
        if (delta < bestDelta)
        {
            bestDelta = delta;
            bestArea = area;
        }
    }

    if (bestArea == Address_Null)
    {
        delete areas;
        return false;
    }

    L4D_GetNavAreaCenter(bestArea, pos);
    delete areas;

    pos[2] += 8.0;
    ang[0] = 0.0;
    ang[1] = GetRandomFloat(0.0, 360.0);
    ang[2] = 0.0;
    return true;
}

public Action SetTankHealthTimer(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (IsValidClient(client) && IsPlayerTank(client))
    {
        SetEntityHealth(client, g_cvTankHealth.IntValue);
    }
    return Plugin_Stop;
}

public Action Timer_EnsureTankOwner(Handle timer, int userid)
{
    int desired = GetClientOfUserId(userid);
    if (!IsValidClient(desired))
        return Plugin_Stop;

    if (IsPlayerTank(desired))
    {
        SetTankControlLockedValue(desired);
        return Plugin_Stop;
    }

    int currentTank = FindHumanOrBotTank();
    if (currentTank > 0 && currentTank != desired && GetFeatureStatus(FeatureType_Native, "L4D_ReplaceTank") == FeatureStatus_Available)
    {
        PrepareClientForTankReplace(desired);
        L4D_ReplaceTank(currentTank, desired);
        CreateTimer(0.2, SetTankHealthTimer, userid, TIMER_FLAG_NO_MAPCHANGE);
    }

    g_iTankOwnerRetries++;
    if (g_iTankOwnerRetries < 10 && !IsPlayerTank(desired))
    {
        CreateTimer(0.5, Timer_EnsureTankOwner, userid, TIMER_FLAG_NO_MAPCHANGE);
    }

    return Plugin_Stop;
}

void PrepareClientForTankReplace(int client)
{
    if (!IsValidClient(client) || IsFakeClient(client))
        return;

    if (GetClientTeam(client) == 3 && IsPlayerAlive(client) && !IsPlayerGhost(client) && !IsPlayerTank(client)
        && GetFeatureStatus(FeatureType_Native, "L4D_ReplaceWithBot") == FeatureStatus_Available)
    {
        L4D_ReplaceWithBot(client);
    }

    if (GetClientTeam(client) == 3 && IsPlayerGhost(client))
    {
        ForcePlayerSuicide(client);
    }
}

int FindHumanOrBotTank()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i) || GetClientTeam(i) != 3 || !IsPlayerAlive(i) || !IsPlayerTank(i))
            continue;

        return i;
    }
    return 0;
}

bool IsPlayerGhost(int client)
{
    return IsValidClient(client) && HasEntProp(client, Prop_Send, "m_isGhost") && GetEntProp(client, Prop_Send, "m_isGhost") != 0;
}

void SetTankControlLockedValue(int client)
{
    if (!g_cvLockTankControl.BoolValue || !IsValidClient(client) || !IsPlayerTank(client))
        return;

    if (HasEntProp(client, Prop_Send, "m_frustration"))
    {
        SetEntProp(client, Prop_Send, "m_frustration", 0);
    }
}

public void OnGameFrame()
{
    if (!g_cvLockTankControl.BoolValue)
        return;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsValidClient(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i) && IsPlayerTank(i))
        {
            SetTankControlLockedValue(i);
        }
    }
}

// ==================== Helpers ====================

bool IsPlayerTank(int client)
{
    if (!IsValidClient(client))
        return false;
    
    int class = GetEntProp(client, Prop_Send, "m_zombieClass");
    return (class == 8);
}

bool IsAllowedInfectedClass(const char[] zombieClass)
{
    return StrEqual(zombieClass, "tank", false)
        || StrEqual(zombieClass, "hunter", false)
        || StrEqual(zombieClass, "jockey", false)
        || StrEqual(zombieClass, "smoker", false)
        || StrEqual(zombieClass, "charger", false)
        || StrEqual(zombieClass, "boomer", false)
        || StrEqual(zombieClass, "spitter", false);
}

void GetInfectedDisplayName(const char[] zombieClass, char[] buffer, int maxlen)
{
    strcopy(buffer, maxlen, zombieClass);
    buffer[0] = CharToUpper(buffer[0]);
}

void ForceStartGame(int client)
{
    ServerCommand("sm_forcestart");

    if (GetFeatureStatus(FeatureType_Native, "L4D_ForceVersusStart") == FeatureStatus_Available && IsVersusMode())
    {
        L4D_ForceVersusStart();
    }
    else if (GetFeatureStatus(FeatureType_Native, "L4D_ForceSurvivalStart") == FeatureStatus_Available && IsSurvivalMode())
    {
        L4D_ForceSurvivalStart();
    }
    else if (GetFeatureStatus(FeatureType_Native, "L4D2_ForceScavengeStart") == FeatureStatus_Available && IsScavengeMode())
    {
        L4D2_ForceScavengeStart();
    }

    CPrintToChatAll("%t", "Force Started", client);
}

bool GetClientAimPosition(int client, float pos[3])
{
    float eyePos[3];
    float eyeAng[3];
    GetClientEyePosition(client, eyePos);
    GetClientEyeAngles(client, eyeAng);

    Handle trace = TR_TraceRayFilterEx(eyePos, eyeAng, MASK_SOLID, RayType_Infinite, TraceFilter_NoPlayers, client);
    if (trace == INVALID_HANDLE)
        return false;

    bool hit = TR_DidHit(trace);
    if (hit)
    {
        TR_GetEndPosition(pos, trace);
    }
    delete trace;
    return hit;
}

public bool TraceFilter_NoPlayers(int entity, int contentsMask, any data)
{
    return entity > MaxClients || entity <= 0;
}

bool IsValidClient(int client)
{
    return (client > 0 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client));
}

bool IsVersusMode()
{
    char gamemode[32];
    FindConVar("mp_gamemode").GetString(gamemode, sizeof(gamemode));
    return (StrEqual(gamemode, "versus", false) || StrEqual(gamemode, "teamversus", false));
}

bool IsCoopMode()
{
    char gamemode[32];
    FindConVar("mp_gamemode").GetString(gamemode, sizeof(gamemode));
    return (StrEqual(gamemode, "coop", false) || StrEqual(gamemode, "realism", false));
}

bool IsSurvivalMode()
{
    char gamemode[32];
    FindConVar("mp_gamemode").GetString(gamemode, sizeof(gamemode));
    return StrEqual(gamemode, "survival", false);
}

bool IsScavengeMode()
{
    char gamemode[32];
    FindConVar("mp_gamemode").GetString(gamemode, sizeof(gamemode));
    return StrEqual(gamemode, "scavenge", false) || StrEqual(gamemode, "teamscavenge", false);
}

// ==================== Events ====================

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client))
    {
        g_bTankDied[client] = false;
        
        int userid = GetClientUserId(client);
        for (int i = 1; i <= MaxClients; i++)
        {
            if (g_iPendingTank[i] == userid)
            {
                g_iPendingTank[i] = 0;
                break;
            }
        }
    }
}

public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client))
        return;
    
    if (IsPlayerTank(client) && !g_bTankDied[client])
    {
        g_bTankDied[client] = true;
        CreateTimer(1.0, Timer_CheckTankAlive, _, TIMER_FLAG_NO_MAPCHANGE);
        CPrintToChatAll("%t", "Tank Killed", client);
    }
}

public void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    g_bTankSpawned = true;

    int tank = GetClientOfUserId(event.GetInt("userid"));
    SetTankControlLockedValue(tank);

    if (g_iDesiredTankOwnerUserId != 0)
    {
        CreateTimer(0.3, Timer_EnsureTankOwner, g_iDesiredTankOwnerUserId, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_CheckTankAlive(Handle timer)
{
    g_bTankSpawned = FindHumanOrBotTank() != 0;
    return Plugin_Stop;
}
