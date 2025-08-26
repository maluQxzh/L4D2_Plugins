#pragma semicolon 1
#include <sourcemod>
#include <sdktools_sound>
#include <left4dhooks>
#define PLUGIN_VERSION "1.1.0"

#define NAV_MESH_PLAYER_START 128 // 玩家起始区域标志

public Plugin:myinfo = 
{
	name = "l4d2_saferoom_smart_recovery",
	author = "maluQxzh",
	description = "Restore health to 50 (100 on some maps)upon entering the next chapter, or retain health under specific circumstances.",
	version = PLUGIN_VERSION,
	url = "https://github.com/maluQxzh/L4D2_Plugins"
}

/*
change log:
v1.1.1
	Remove ConVar "l4d2_saferoom_smart_recovery_RemoveBlackAndWhite", plugin automatically handles whether to remove black and white status
	When players trigger temporary health retention to the next chapter, the plugin will not perform any processing
v1.1.0
	Optimized the decision logic for health restoration at the beginning of chapters
v1.0.2
	Fix Bugs
v1.0.1
	Fix Bugs
v1.0.0
	Initial Release
*/

int
	iSurvivorRespawnHealth,
	iCustomSaferoomHealth,
	iUseCustomValue,
	//iRemoveBlackAndWhite,
	iHealthToSet,
	iUseTempHealthRemain,
	iTempHealthRemainValue,
	iDebugInfo,
	g_iPlayerCheckTime,
	g_iPlayerHealedFlags;  // 用于记录已处理的玩家位标记
ConVar
	hUseCustomValue,
	hCustomSaferoomHealth,
	//hRemoveBlackAndWhite,
	hUseTempHealthRemain,
	hTempHealthRemainValue,
	hDebugInfo;
bool
	g_bInfoPlayerStartHasAttribute;
	g_bIsLeftSafeArea;

public void OnPluginStart()
{
	decl String:game_name[64];
	GetGameFolderName(game_name, sizeof(game_name));
	if (!StrEqual(game_name, "left4dead2", false))
	{		
		SetFailState("Plugin supports Left 4 Dead 2 only.");
	}
	
	CreateConVar("l4d2_saferoom_smart_recovery_version", PLUGIN_VERSION, "l4d2_saferoom_smart_recovery version", FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD);
	
	hUseCustomValue = CreateConVar("l4d2_saferoom_smart_recovery_CanWeUseCustomValue", "0", "0=默认为50(z_survivor_respawn_health)(部分地图为100)，1=启用自定义恢复值   If set to 0, the default recovery value is 50 (100 on some maps); if set to 1, custom recovery values are enabled.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	hCustomSaferoomHealth = CreateConVar("l4d2_saferoom_smart_recovery_CustomSaferoomHealth", "50", "启用自定义恢复值时有效，回复至多少生命值   Effective if custom recovery values are enabled – how much health is restored to.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 1.0, true, 100.0);
	//hRemoveBlackAndWhite = CreateConVar("l4d2_saferoom_smart_recovery_RemoveBlackAndWhite", "1", "是否移除黑白和心跳声   Whether to remove the black and white effect and heartbeat sound.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	hUseTempHealthRemain = CreateConVar("l4d2_saferoom_smart_recovery_UseTempHealthRemain", "1", "是否启用保留虚血   Whether to enable remaining temporary health values.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	hTempHealthRemainValue = CreateConVar("l4d2_saferoom_smart_recovery_TempHealthRemainValue", "20", "启用保留虚血时有效，实血+虚血大于等于设定恢复值多少时保留   Effective when retaining temporary health values is enabled. Retain when the sum of health and temporary health is greater than or equal to TempHealthRemainValue.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 99.0);
	hDebugInfo = CreateConVar("l4d2_saferoom_smart_recovery_hDebugInfo", "0", "是否输出调试信息", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	
	AutoExecConfig(true, "l4d2_saferoom_smart_recovery");
	
	HookEvent("map_transition", Event_MapTransition, EventHookMode_Pre);
	HookEvent("round_start_post_nav", Event_RoundStartPostNav, EventHookMode_PostNoCopy);
	//HookEvent("round_end", Event_RoundEnd);
	HookEvent("player_left_safe_area", Event_PlayerLeftSafeArea);
}

bool PrintDebugInfo(ConVar hd)
{
	iDebugInfo = hd.IntValue;
	if (iDebugInfo)
		return true;
	else
		return false;
}

int GetPlayerTempHealth(int client)
{
	static Handle painPillsDecayCvar = null;
	if (painPillsDecayCvar == null)
	{
		painPillsDecayCvar = FindConVar("pain_pills_decay_rate");
		if (painPillsDecayCvar == null)
			return -1;
	}

	int tempHealth = RoundToCeil(GetEntPropFloat(client, Prop_Send, "m_healthBuffer") - ((GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime")) * GetConVarFloat(painPillsDecayCvar))) - 1;
	if (PrintDebugInfo(hDebugInfo))
		PrintToChat(client, "你的临时生命值：%i", tempHealth);
	return tempHealth < 0 ? 0 : tempHealth;
}

void RemoveBlackAndWhite(int client)
{
	SetEntProp(client, Prop_Send, "m_currentReviveCount", 0);
	SetEntProp(client, Prop_Send, "m_bIsOnThirdStrike", 0);
	StopSound(client, SNDCHAN_AUTO, "player/heartbeatloop.wav");
}

void SetPlayerHealth(int client, int value)
{
	SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 0.0);
	SetEntityHealth(client, value);
}

//挂边状态.
bool IsPlayerFalling(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated") && GetEntProp(client, Prop_Send, "m_isHangingFromLedge");
}
//倒地状态.
bool IsPlayerFallen(int client)
{
	return GetEntProp(client, Prop_Send, "m_isIncapacitated") && !GetEntProp(client, Prop_Send, "m_isHangingFromLedge");
}

bool CheckPosition(float pos[3])
{
	// 使用left4dhooks API获取最近的导航区域
	Address area = L4D_GetNearestNavArea(pos, 220.0, true, false, false, 0);//位置；搜索距离；忽略高度差距；检查视线；检查地面连接；类型

	if (area == Address_Null)
	{
		return false;
	}

	// 获取区域属性
	int attributes = L4D_GetNavArea_SpawnAttributes(area);
	
	// 检测是否存在包含player_start属性的区域
	bool isPlayerStart = (attributes & NAV_MESH_PLAYER_START) != 0;

	if (isPlayerStart)
	{
		return true;
	}
	else
	{
		return false;
	}
}

bool CheckPlayerReady(int client)
{
	if ((IsClientConnected(client) && !IsClientInGame(client)) || !IsClientConnected(client))
	{
		return false;
	}
	return true;
}

bool CheckEntityHasAttribute()
{
	int entity = -1;
	float origin[3];

	while ((entity = FindEntityByClassname(entity, "info_player_start")) != -1)
	{
		if (PrintDebugInfo(hDebugInfo))
			PrintToChatAll("info_player_start entity: Find");
		GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);
		if (CheckPosition(origin))
		{
			//foundPlayerStart = true;
			if (PrintDebugInfo(hDebugInfo))
				PrintToChatAll("NAV_MESH_PLAYER_START: Yes");
			return true;
		}
		else
		{
			return false;
		}
	}
	if (PrintDebugInfo(hDebugInfo))
			PrintToChatAll("info_player_start entity: Not Find");
	return false;
}

bool CheckAllPlayerReady()
{
	for (new i = 1; i <= MaxClients; i++)
	{
		if ((IsClientConnected(i)) == true && (IsClientInGame(i)== false))
		{
			return false;
		}
	}
	if (PrintDebugInfo(hDebugInfo))
		PrintToChatAll("AllPlayerReady");
	return true;
}

public void Event_RoundStartPostNav(Event event, const char[] name, bool dontBroadcast)
{
	if (PrintDebugInfo(hDebugInfo))
			PrintToChatAll("MapNavComplete");
	
	g_iPlayerCheckTime = 0;
	g_iPlayerHealedFlags = 0;
	g_bInfoPlayerStartHasAttribute = false;
	g_bIsLeftSafeArea = false;

	iUseCustomValue = hUseCustomValue.IntValue;
	if (iUseCustomValue == 0)
	{	
		if (CheckEntityHasAttribute())
		{
			g_bInfoPlayerStartHasAttribute = true;
		}

		CreateTimer(0.5, Timer_RoundStart, _, TIMER_REPEAT);
	}
}

public void Event_PlayerLeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    g_bIsLeftSafeArea = true;
}

public Action Event_MapTransition(Handle:event, const String:name[], bool:dontBroadcast) 
{	
	iCustomSaferoomHealth = hCustomSaferoomHealth.IntValue;
	iUseCustomValue = hUseCustomValue.IntValue;
	iSurvivorRespawnHealth = FindConVar("z_survivor_respawn_health").IntValue;
	//iRemoveBlackAndWhite = hRemoveBlackAndWhite.IntValue;
	iUseTempHealthRemain = hUseTempHealthRemain.IntValue;
	iTempHealthRemainValue = hTempHealthRemainValue.IntValue;
	
	if (iUseCustomValue == 1)
	{
		iHealthToSet = iCustomSaferoomHealth;
	}
	else
	{
		iHealthToSet = iSurvivorRespawnHealth;
	}
	for (new i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i) && IsClientInGame(i) && GetClientTeam(i) == 2)
		{
			if (IsPlayerFalling(i))
			{
				L4D2_VScriptWrapper_ReviveFromIncap(i);
			}
			if (IsPlayerFallen(i))
			{
				L4D2_VScriptWrapper_ReviveFromIncap(i);
			}
			//SetEntProp(i, Prop_Send, "m_iHideHUD", 64);
			if (iUseTempHealthRemain == 1)
			{
				if ((GetClientHealth(i) + GetPlayerTempHealth(i) <= iHealthToSet + iTempHealthRemainValue) && (GetClientHealth(i) < iHealthToSet))
				{
					SetPlayerHealth(i, iHealthToSet);
					RemoveBlackAndWhite(i);
				}
			}
			else
			{
				if (GetClientHealth(i) <= iHealthToSet)
				{
					SetPlayerHealth(i, iHealthToSet);
					RemoveBlackAndWhite(i);
				}
			}
		}
	}
	
	return Plugin_Continue;
}

void RoundStartHealingForPlayer(int client)
{
	if (g_bInfoPlayerStartHasAttribute)
	{
		if (GetClientHealth(client) < 100)
		{
			SetPlayerHealth(client, 100);
			RemoveBlackAndWhite(client);
			if (PrintDebugInfo(hDebugInfo))
				PrintToServer("Healing");
		}
		return;
	}
	else
	{
		float pos[3];
		GetClientAbsOrigin(client, pos);
		if (CheckPosition(pos))
		{
			if (GetClientHealth(client) < 100)
			{
				if (PrintDebugInfo(hDebugInfo))
					PrintToChat(client, "NAV_MESH_PLAYER_START: Yes");
				if (PrintDebugInfo(hDebugInfo))
					PrintToServer("Healing");
				SetPlayerHealth(client, 100);
				RemoveBlackAndWhite(client);
			}
		}
		else
		{
			if (PrintDebugInfo(hDebugInfo))
				PrintToChat(client, "NAV_MESH_PLAYER_START: No");
			if (PrintDebugInfo(hDebugInfo))
				PrintToServer("No Healing");
		}
	}
}

public Action Timer_RoundStart(Handle timer)
{	
	g_iPlayerCheckTime++;
	if (PrintDebugInfo(hDebugInfo))
		PrintToServer("PlayerCheckTime: %d", g_iPlayerCheckTime);
	
	// 检查每个玩家，对已准备好的玩家进行治疗
	for (new i = 1; i <= MaxClients; i++)
	{
		if (CheckPlayerReady(i))
		{
			// 玩家已准备好且未被治疗过
			if (!(g_iPlayerHealedFlags & (1 << i)) && GetClientTeam(i) == 2)
			{
				RoundStartHealingForPlayer(i);
			}
			g_iPlayerHealedFlags |= (1 << i);  // 标记玩家已检查
		}
	}

	if (CheckAllPlayerReady())
	{
		return Plugin_Stop;
	}
	
	// 如果超过600次检查（五分钟）仍然有玩家未准备好或有玩家已经离开安全区域，停止定时器
	if (g_iPlayerCheckTime >= 600 || g_bIsLeftSafeArea)
	{
		if (PrintDebugInfo(hDebugInfo))
			PrintToChatAll("CheckAllPlayerReadyFalse");
		return Plugin_Stop;
	}
	
	return Plugin_Continue;
}