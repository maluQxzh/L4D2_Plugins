#pragma semicolon 1
#include <sourcemod>
#include <sdktools_sound>
#include <left4dhooks>
#define PLUGIN_VERSION "1.0" 

#define NAV_MESH_PLAYER_START 128 // 玩家起始区域标志

public Plugin:myinfo = 
{
	name = "L4D_SaferoomSmartRecovery",
	author = "maluQxzh",
	description = "Restore health to 50 (100 on some maps)upon entering the next chapter, or retain health under specific circumstances.",
	version = PLUGIN_VERSION,
	url = "https://github.com/maluQxzh/L4D2_Plugins"
}

int
	iSurvivorRespawnHealth,
	iCustomSaferoomHealth,
	iUseCustomValue,
	iRemoveBlackAndWhite,
	iHealthToSet,
	iUseTempHealthRemain,
	iTempHealthRemainValue,
	iDebugInfo;
	g_iPlayerSpawn;
ConVar
	hUseCustomValue,
	hCustomSaferoomHealth,
	hRemoveBlackAndWhite,
	hUseTempHealthRemain,
	hTempHealthRemainValue,
	hDebugInfo;

public void OnPluginStart()
{
	decl String:game_name[64];
	GetGameFolderName(game_name, sizeof(game_name));
	if (!StrEqual(game_name, "left4dead2", false) && !StrEqual(game_name, "left4dead", false))
	{		
		SetFailState("Plugin supports Left 4 Dead series only.");
	}
	
	CreateConVar("L4D_SaferoomSmartRecovery_Version", PLUGIN_VERSION, "L4D_SaferoomSmartRecovery Version", FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD);
	
	hUseCustomValue = CreateConVar("L4D_SaferoomSmartRecovery_CanWeUseCustomValue", "0", "0=默认为50(z_survivor_respawn_health)(部分地图为100)，1=启用自定义恢复值   If set to 0, the default recovery value is 50 (100 on some maps); if set to 1, custom recovery values are enabled.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	hCustomSaferoomHealth = CreateConVar("L4D_SaferoomSmartRecovery_CustomSaferoomHealth", "50", "启用自定义恢复值时有效，回复至多少生命值   Effective if custom recovery values are enabled – how much health is restored to.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 1.0, true, 100.0);
	hRemoveBlackAndWhite = CreateConVar("L4D_SaferoomSmartRecovery_RemoveBlackAndWhite", "1", "是否移除黑白和心跳声   Whether to remove the black and white effect and heartbeat sound.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	hUseTempHealthRemain = CreateConVar("L4D_SaferoomSmartRecovery_UseTempHealthRemain", "1", "是否启用保留虚血   Whether to enable remaining temporary health values.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	hTempHealthRemainValue = CreateConVar("L4D_SaferoomSmartRecovery_TempHealthRemainValue", "20", "启用保留虚血时有效，实血+虚血大于等于设定恢复值多少时保留   Effective when retaining temporary health values is enabled. Retain when the sum of health and temporary health is greater than or equal to TempHealthRemainValue.", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 99.0);
	hDebugInfo = CreateConVar("L4D_SaferoomSmartRecovery_hDebugInfo", "0", "是否输出调试信息", FCVAR_NOTIFY|FCVAR_REPLICATED, true, 0.0, true, 1.0);
	
	AutoExecConfig(true, "L4D_SaferoomSmartRecovery");
	
	HookEvent("map_transition", Event_MapTransition, EventHookMode_Pre);
	//HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_PostNoCopy);
	HookEvent("round_end", Event_RoundEnd);
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

public void OnMapStart()
{
	g_iPlayerSpawn = 0;
}

public void OnMapEnd()
{
	g_iPlayerSpawn = 0;
}

void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	if (g_iPlayerSpawn != 1)
	{
		if (PrintDebugInfo(hDebugInfo))
			PrintToChatAll("PlayerchapterFirstSpawn");
		CreateTimer(0.5, Timer_RoundStart, _, TIMER_FLAG_NO_MAPCHANGE);
		g_iPlayerSpawn = 1;
	}
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	if (PrintDebugInfo(hDebugInfo))
		PrintToChatAll("RoundEnd");
	g_iPlayerSpawn = 0;
}

public Action Event_MapTransition(Handle:event, const String:name[], bool:dontBroadcast) 
{	
	iCustomSaferoomHealth = hCustomSaferoomHealth.IntValue;
	iUseCustomValue = hUseCustomValue.IntValue;
	iSurvivorRespawnHealth = FindConVar("z_survivor_respawn_health").IntValue;
	iRemoveBlackAndWhite = hRemoveBlackAndWhite.IntValue;
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
		if (IsClientConnected(i) && GetClientTeam(i) == 2)
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
			if (iRemoveBlackAndWhite == 1)
			{
			RemoveBlackAndWhite(i);
			}
			if (iUseTempHealthRemain == 1)
			{
				if ((GetClientHealth(i) + GetPlayerTempHealth(i) <= iHealthToSet + iTempHealthRemainValue) && (GetClientHealth(i) < iHealthToSet))
				{
					SetPlayerHealth(i, iHealthToSet);
				}
			}
			else
			{
				if (GetClientHealth(i) <= iHealthToSet)
				{
					SetPlayerHealth(i, iHealthToSet);
				}
			}
		}
	}
	g_iPlayerSpawn = 0;
	return Plugin_Continue;
}

public Action Timer_RoundStart(Handle timer)
{
	if (iUseCustomValue == 0)
	{
		int entity = -1;
		float origin[3];
		while ((entity = FindEntityByClassname(entity, "info_player_start")) != -1)
		{
			if (PrintDebugInfo(hDebugInfo))
				PrintToChatAll("info_player_start entity: find");
			GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);
			if (CheckPosition(origin))
			{
				if (PrintDebugInfo(hDebugInfo))
					PrintToChatAll("NAV_MESH_PLAYER_START: Yes");
				for (new i = 1; i <= MaxClients; i++)
				{
					if (IsClientConnected(i) && GetClientTeam(i) == 2)
					{
						RemoveBlackAndWhite(i);
						if (GetClientHealth(i) < 100)
						{
							SetPlayerHealth(i, 100);
						}
					}
				}
			}
			else
			{
				if (PrintDebugInfo(hDebugInfo))
					PrintToChatAll("NAV_MESH_PLAYER_START: No");
			}
			return Plugin_Continue;
		}
		if (PrintDebugInfo(hDebugInfo))
			PrintToChatAll("info_player_start entity: not find");
		for (new i = 1; i <= MaxClients; i++)
		{
			if (IsClientConnected(i) && GetClientTeam(i) == 2)
			{
				float pos[3];
				// 获取玩家当前位置
				GetClientAbsOrigin(i, pos);
				if (CheckPosition(pos))
				{
					RemoveBlackAndWhite(i);
					if (GetClientHealth(i) < 100)
					{
						SetPlayerHealth(i, 100);
					}
				}
				else
				{
					if (PrintDebugInfo(hDebugInfo))
						PrintToChat(i, "NAV_MESH_PLAYER_START: No");
				}
			}
			
		}
		return Plugin_Continue;
	}
	return Plugin_Continue;
}