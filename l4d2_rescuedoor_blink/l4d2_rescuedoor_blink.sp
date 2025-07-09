#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <multicolors>
#define PLUGIN_VERSION "1.0.0"

#define MAX_SEARCH_DIST 1500

#define NAV_MESH_EMPTY 2
#define NAV_MESH_STOP_SCAN 4
#define NAV_MESH_BATTLESTATION 32
#define NAV_MESH_FINALE 64
#define NAV_MESH_PLAYER_START 128
#define NAV_MESH_BATTLEFIELD 256
#define NAV_MESH_IGNORE_VISIBILITY 512
#define NAV_MESH_NOT_CLEARABLE 1024
#define NAV_MESH_CHECKPOINT 2048
#define NAV_MESH_OBSCURED 4096
#define NAV_MESH_NO_MOBS 8192
#define NAV_MESH_THREAT 16384
#define NAV_MESH_RESCUE_VEHICLE 32768
#define NAV_MESH_RESCUE_CLOSET 65536
#define NAV_MESH_ESCAPE_ROUTE 131072
#define NAV_MESH_DESTROYED_DOOR 262144
#define NAV_MESH_NOTHREAT 524288
#define NAV_MESH_LYINGDOWN 1048576


public Plugin:myinfo = 
{
	name = "l4d2_rescuedoor_blink",
	author = "maluQxzh",
	description = "Make rescue doors blink with customizable colors and timing",
	version = PLUGIN_VERSION,
	url = "https://github.com/maluQxzh/L4D2_Plugins"
}

int
    currentCount;
ArrayList
    g_BlinkingDoors,
    g_BlinkColors;    // 存储颜色数组
Handle
    g_hTimer = null;
ConVar
    g_hBlinkSpeed,    // 闪烁速度（间隔时间）
    g_hBlinkCount,    // 一轮闪烁的颜色数量
    g_hBlinkColors;   // 颜色字符串（RGB值）

public void OnPluginStart()
{
    decl String:game_name[64];
    GetGameFolderName(game_name, sizeof(game_name));
    if (!StrEqual(game_name, "left4dead2", false))
    {
        SetFailState("Plugin supports Left 4 Dead 2 only.");
    }

    CreateConVar("l4d2_rescuedoor_blink_version", PLUGIN_VERSION, "l4d2_rescuedoor_blink version", FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD);

    // 创建配置变量
    g_hBlinkSpeed = CreateConVar("l4d2_rescuedoor_blink_speed", "1.0", "闪烁间隔时间（秒）Blink interval time (seconds)", FCVAR_NOTIFY, true, 0.1, true, 10.0);
    g_hBlinkCount = CreateConVar("l4d2_rescuedoor_blink_count", "3", "一轮闪烁的颜色数量 Number of colors in one blink cycle", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    g_hBlinkColors = CreateConVar("l4d2_rescuedoor_blink_colors", "255,0,0,255;255,255,0,255;255,255,255,255", "闪烁颜色列表(R,G,B,A格式，用分号分隔) Blink colors list (R,G,B,A format, separated by semicolon)", FCVAR_NOTIFY);

    AutoExecConfig(true, "l4d2_rescuedoor_blink");

    g_BlinkingDoors = new ArrayList();
    g_BlinkColors = new ArrayList(4); // 存储RGBA值，每个颜色4个值

    // 初始化颜色配置
    UpdateBlinkColors();
    
    // 当配置变量改变时更新颜色配置
    HookConVarChange(g_hBlinkColors, OnColorCvarChanged);
    HookConVarChange(g_hBlinkSpeed, OnBlinkSpeedChanged);

    // 添加调试命令
    RegConsoleCmd("sm_blink_reload", Command_ReloadBlinkConfig, "重新加载闪烁配置");
    RegConsoleCmd("sm_blink_info", Command_BlinkInfo, "显示当前闪烁配置信息");
    RegConsoleCmd("sm_test", Command_MyCommand, "测试指令");

    //HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_start_post_nav", Event_RoundStartPostNav, EventHookMode_PostNoCopy);
    //HookEvent("map_transition", Event_MapTransition, EventHookMode_Pre);
    HookEvent("player_left_safe_area", Event_PlayerLeftSafeArea);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("rescue_door_open", Event_RescueDoorOpen);
    HookEvent("round_end", Event_RoundEnd);
    HookEvent("map_transition", Event_MapTransition, EventHookMode_Pre);
    //HookEvent("player_spawn", Event_PlayerSpawn);
    HookEvent("survivor_rescued", Event_SurvivorRescued);
}

public Action Command_MyCommand(int client, int args)
{
    PrintToChatAll("test start");
    float origin[3];
    int find_entity = FindNearestEntity_client(client, "info_survivor_rescue");
    GetEntPropVector(find_entity, Prop_Data, "m_vecOrigin", origin);
    CheckPosition(origin);
    int find_entity_2 = FindNearestEntity_client(client, "prop_door_rotating");
    int isRescueDoor_2 = GetEntProp(find_entity_2, Prop_Send, "m_isRescueDoor");
    PrintToChatAll("prop_door m_isRescueDoor = %d", isRescueDoor_2);
    //int find_entity_3 = FindNearestEntity_client(client, "func_door_rotating");
    //int isRescueDoor_3 = GetEntProp(find_entity_3, Prop_Send, "m_isRescueDoor");
    //PrintToChatAll("func_door m_isRescueDoor = %d", isRescueDoor_3);
    if (isRescueDoor_2 == 1)
    {
        PrintToChatAll("是救援门");
    }
    else
    {
        PrintToChatAll("不是救援门");
    }

    return Plugin_Handled;
}

// 解析颜色配置字符串
void UpdateBlinkColors()
{
    g_BlinkColors.Clear();
    
    char colorString[512];
    GetConVarString(g_hBlinkColors, colorString, sizeof(colorString));
    
    char colorParts[32][64]; // 最多32种颜色
    int colorCount = ExplodeString(colorString, ";", colorParts, sizeof(colorParts), sizeof(colorParts[]));
    //int ExplodeString(const char[] text, const char[] split, char[][] buffers, int maxStrings, int maxStringLength, bool copyRemainder = true)
    
    for (int i = 0; i < colorCount; i++)
    {
        char rgbaParts[4][16];
        int rgbaCount = ExplodeString(colorParts[i], ",", rgbaParts, sizeof(rgbaParts), sizeof(rgbaParts[]));
        
        if (rgbaCount == 4)
        {
            int r = StringToInt(rgbaParts[0]);
            int g = StringToInt(rgbaParts[1]);
            int b = StringToInt(rgbaParts[2]);
            int a = StringToInt(rgbaParts[3]);
            
            // 限制颜色值范围
            r = (r < 0) ? 0 : ((r > 255) ? 255 : r);
            g = (g < 0) ? 0 : ((g > 255) ? 255 : g);
            b = (b < 0) ? 0 : ((b > 255) ? 255 : b);
            a = (a < 0) ? 0 : ((a > 255) ? 255 : a);
            
            g_BlinkColors.Push(r);
            g_BlinkColors.Push(g);
            g_BlinkColors.Push(b);
            g_BlinkColors.Push(a);
        }
    }
    
    // 如果没有有效颜色，使用默认颜色
    if (g_BlinkColors.Length == 0)
    {
        // 默认红色
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(0);
        g_BlinkColors.Push(0);
        g_BlinkColors.Push(255);
        
        // 默认黄色
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(0);
        g_BlinkColors.Push(255);
        
        // 默认白色
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(255);
    }
}

// 配置变量改变时的回调
public void OnColorCvarChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    UpdateBlinkColors();
}

public void OnBlinkSpeedChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    // 重新启动计时器以应用新的速度
    if (g_hTimer != null)
    {
        CloseHandle(g_hTimer);
        g_hTimer = null;
        
        float blinkSpeed = GetConVarFloat(g_hBlinkSpeed);
        g_hTimer = CreateTimer(blinkSpeed, Timer_DoorBlink, _, TIMER_REPEAT);
    }
}

// 重载配置命令
public Action Command_ReloadBlinkConfig(int client, int args)
{
    UpdateBlinkColors();
    
    if (client > 0)
    {
        CPrintToChat(client, "{olive}[闪烁插件]{default} 配置已重新加载");
    }
    else
    {
        PrintToServer("[闪烁插件] 配置已重新加载");
    }
    
    return Plugin_Handled;
}

// 显示配置信息命令
public Action Command_BlinkInfo(int client, int args)
{
    float blinkSpeed = GetConVarFloat(g_hBlinkSpeed);
    int blinkCount = GetConVarInt(g_hBlinkCount);
    int colorCount = g_BlinkColors.Length / 4;
    
    if (client > 0)
    {
        CPrintToChat(client, "{green}[闪烁插件]{default} 当前配置:");
        CPrintToChat(client, "  {lightgreen}闪烁速度:{default} {green}%.1f{default} 秒", blinkSpeed);
        CPrintToChat(client, "  {lightgreen}配置颜色数:{default} {green}%d{default}", blinkCount);
        CPrintToChat(client, "  {lightgreen}解析颜色数:{default} {green}%d{default}", colorCount);
        CPrintToChat(client, "  {lightgreen}正在闪烁的门:{default} {green}%d{default}", g_BlinkingDoors.Length);
        
        // 显示颜色详情
        for (int i = 0; i < colorCount && i < 5; i++) // 最多显示5个颜色
        {
            int arrayIndex = i * 4;
            int r = g_BlinkColors.Get(arrayIndex);
            int g = g_BlinkColors.Get(arrayIndex + 1);
            int b = g_BlinkColors.Get(arrayIndex + 2);
            int a = g_BlinkColors.Get(arrayIndex + 3);
            CPrintToChat(client, "  {olive}颜色%d:{default} R={red}%d{default} G={olive}%d{default} B={blue}%d{default} A={lightgreen}%d{default}", i + 1, r, g, b, a);
        }
    }
    else
    {
        PrintToServer("[闪烁插件] 当前配置:");
        PrintToServer("  闪烁速度: %.1f 秒", blinkSpeed);
        PrintToServer("  配置颜色数: %d", blinkCount);
        PrintToServer("  解析颜色数: %d", colorCount);
        PrintToServer("  正在闪烁的门: %d", g_BlinkingDoors.Length);
    }
    
    return Plugin_Handled;
}

// 安全地设置实体颜色和渲染模式
void SafeSetEntityColor(int entity, int r, int g, int b, int a)
{
    if (!IsValidEntity(entity))
        return;
        
    // 先设置渲染模式，确保颜色能正确显示
    SetEntProp(entity, Prop_Send, "m_nRenderMode", 1); // kRenderTransColor
    
    // 设置颜色
    SetEntityRenderColor(entity, r, g, b, a);
    
    // 确保实体可见
    SetEntProp(entity, Prop_Send, "m_fEffects", GetEntProp(entity, Prop_Send, "m_fEffects") & ~32); // 移除EF_NODRAW
}

public void CheckPosition(float pos[3])
{
    // 使用left4dhooks API获取最近的导航区域
    Address area = L4D_GetNearestNavArea(pos, 220.0, true, false, false, 0);//位置；搜索距离；忽略高度差距；检查视线；检查地面连接；类型
    if (area == Address_Null)
    {
        return;
    }

    // 获取区域属性
    int attributes = L4D_GetNavArea_SpawnAttributes(area);
    // 检测是否存在包含XX属性的区域
    if((attributes & NAV_MESH_EMPTY) != 0 )
        PrintToChatAll("1");
    else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_STOP_SCAN) != 0 )
        PrintToChatAll("1");
    else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_BATTLESTATION) != 0 )
        PrintToChatAll("1");
    else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_FINALE) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_PLAYER_START) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_BATTLEFIELD) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_IGNORE_VISIBILITY) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_NOT_CLEARABLE) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_CHECKPOINT) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_OBSCURED) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_NO_MOBS) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_THREAT) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_RESCUE_VEHICLE) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_RESCUE_CLOSET) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_ESCAPE_ROUTE) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_DESTROYED_DOOR) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_NOTHREAT) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    if((attributes & NAV_MESH_LYINGDOWN) != 0 )
        PrintToChatAll("1");
        else
        PrintToChatAll("0");
    
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        int door = g_BlinkingDoors.Get(i);
        //int isRescueDoor = GetEntProp(door, Prop_Send, "m_isRescueDoor");
        PrintToChatAll("RescueDoor:%d", door);
        // if (isRescueDoor == 1)
        // {
        //     PrintToChatAll("是复活门");
        // }
    }
}

int FindNearestEntity_client(int i, const char[] className)
{
    //if (!IsValidEntity(referenceEntity)) return -1;

    // 获取参考实体的位置
    float refPos[3];
    //GetEntPropVector(referenceEntity, Prop_Send, "m_vecOrigin", refPos);
    GetClientAbsOrigin(i, refPos);

    int nearestEntity = -1;
    float minDistance = -1.0;

    // 遍历所有实体
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, className)) != -1)
    {
        // 跳过自身
        //if (entity == referenceEntity) continue;
        
        // 获取目标实体位置
        float targetPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", targetPos);
        
        // 计算距离
        float distance = GetVectorDistance(refPos, targetPos);

        // 跳过过远的实体
        if (distance > MAX_SEARCH_DIST) continue;
        
        // 更新最近实体
        if (minDistance < 0 || distance < minDistance)
        {
            minDistance = distance;
            nearestEntity = entity;
        }
    }
    
    return nearestEntity; // 返回最近的实体ID，未找到返回-1
}

//在参考实体周围查找最近的指定类别实体
int FindNearestEntity(int referenceEntity, const char[] className)
{
    if (!IsValidEntity(referenceEntity))
    {
        //PrintToChatAll("无效实体");
        return -1;
    }
    // 获取参考实体的位置
    float refPos[3];
    GetEntPropVector(referenceEntity, Prop_Send, "m_vecOrigin", refPos);

    int nearestEntity = -1;
    float minDistance = -1.0;

    // 遍历所有实体
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, className)) != -1)
    {
        // 跳过自身
        if (entity == referenceEntity) continue;
        
        // 获取目标实体位置
        float targetPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", targetPos);
        
        // 计算距离
        float distance = GetVectorDistance(refPos, targetPos);

        // 跳过过远的实体
        if (distance > MAX_SEARCH_DIST) continue;
    
        // 更新最近实体
        if (minDistance < 0 || distance < minDistance)
        {
            minDistance = distance;
            nearestEntity = entity;
        }
    }
    
    return nearestEntity; // 返回最近的实体ID，未找到返回-1
}

int FindNearestRescueDoorEntity(int referenceEntity)
{
    if (!IsValidEntity(referenceEntity)) return -1;

    // 获取参考实体的位置
    float refPos[3];
    GetEntPropVector(referenceEntity, Prop_Send, "m_vecOrigin", refPos);

    char doorTypes[][64] = {
    "func_door_rotating",
    "prop_door_rotating",
    "prop_door_rotating_checkpoint"
    };

    int nearestEntity = -1;
    float minDistance = -1.0;

    // 遍历所有门类型
    for (int i = 0; i < sizeof(doorTypes); i++)
    {
        int entity = -1;
        while ((entity = FindEntityByClassname(entity, doorTypes[i])) != -1)
        {
            // 跳过自身和无效实体
            if (entity == referenceEntity || !IsValidEntity(entity))
                continue;

            float targetPos[3];
            GetEntPropVector(entity, Prop_Send, "m_vecOrigin", targetPos);

            // 计算距离
            float distance = GetVectorDistance(refPos, targetPos);

            // 跳过过远的实体
            if (distance > MAX_SEARCH_DIST) continue;
        
            // 更新最近实体
            if (minDistance < 0 || distance < minDistance)
            {
                minDistance = distance;
                nearestEntity = entity;
            }
        }
    }

    return nearestEntity; // 返回最近的实体ID，未找到返回-1
}

bool PushUnique(ArrayList array, int value)
{
    if (array == null) return false;
    
    // 检查是否已存在
    if (array.FindValue(value) != -1) {
        return false; // 已存在，不添加
    }
    
    // 添加新元素
    array.Push(value);
    return true;
}

public void EndDoorBlink(int door)
{
    if (!IsValidEntity(door)) return;
    
    // 恢复默认颜色和渲染模式
    SetEntityRenderColor(door, 255, 255, 255, 255);
    SetEntProp(door, Prop_Send, "m_nRenderMode", 0); // kRenderNormal
}

bool CheckPosition_FINALE(float pos[3])
{
	// 使用left4dhooks API获取最近的导航区域
	Address area = L4D_GetNearestNavArea(pos, 220.0, true, false, false, 0);//位置；搜索距离；忽略高度差距；检查视线；检查地面连接；类型

	if (area == Address_Null)
	{
		return false;
	}

	// 获取区域属性
	int attributes = L4D_GetNavArea_SpawnAttributes(area);
	
	// 检测是否存在包含RESCUE_CLOSET属性的区域
	bool isFi = (attributes & NAV_MESH_FINALE) != 0;

	if (isFi)
	{
		return true;
	}
	else
	{
		return false;
	}
}

bool CheckPosition_RESCUE_CLOSET(float pos[3])
{
	// 使用left4dhooks API获取最近的导航区域
	Address area = L4D_GetNearestNavArea(pos, 220.0, true, false, false, 0);//位置；搜索距离；忽略高度差距；检查视线；检查地面连接；类型

	if (area == Address_Null)
	{
		return false;
	}

	// 获取区域属性
	int attributes = L4D_GetNavArea_SpawnAttributes(area);
	
	// 检测是否存在包含RESCUE_CLOSET属性的区域
	bool isRC = (attributes & NAV_MESH_RESCUE_CLOSET) != 0;

	if (isRC)
	{
		return true;
	}
	else
	{
		return false;
	}
}

public void Event_RoundStartPostNav(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(3.0, Timer_RoundStart, _, _);
}

public Action Timer_RoundStart(Handle timer)
{
    currentCount = 0;
    if (g_hTimer != null)
    {
        CloseHandle(g_hTimer); // 停止计时器
        g_hTimer = null;
    }
    g_BlinkingDoors.Clear();

    int entity = -1;
    int find_entity = -1;
    float origin[3];
    while ((entity = FindEntityByClassname(entity, "info_survivor_rescue")) != -1)
    {
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);
        if (CheckPosition_RESCUE_CLOSET(origin))
        {
            //PrintToChatAll("NAV_MESH_RESCUE_CLOSET:Yes");
            find_entity = FindNearestRescueDoorEntity(entity);
            if (HasEntProp(find_entity, Prop_Send, "m_isRescueDoor"))
            {
                int isRescueDoor = GetEntProp(find_entity, Prop_Send, "m_isRescueDoor");
                if (isRescueDoor == 1)
                {
                    PushUnique(g_BlinkingDoors, find_entity);
                }
            }
            else
            {
                PushUnique(g_BlinkingDoors, find_entity);
            }
            
        }
        else
        {
            //PrintToChatAll("NAV_MESH_RESCUE_CLOSET:No");
        }
    }
    
    // 使用配置的闪烁速度
    float blinkSpeed = GetConVarFloat(g_hBlinkSpeed);
    g_hTimer = CreateTimer(blinkSpeed, Timer_DoorBlink, _, TIMER_REPEAT);

    return Plugin_Continue;
}

public Action Timer_DoorBlink(Handle timer)
{
    // 如果没有可用的颜色，返回
    if (g_BlinkColors.Length == 0)
    {
        return Plugin_Continue;
    }
    
    int blinkCount = GetConVarInt(g_hBlinkCount);
    int colorCount = g_BlinkColors.Length / 4; // 每个颜色4个值(RGBA)
    
    // 限制闪烁计数在有效范围内
    if (blinkCount > colorCount)
    {
        blinkCount = colorCount;
    }
    
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        int door = g_BlinkingDoors.Get(i);
        if (!IsValidEntity(door))
        {
            g_BlinkingDoors.Erase(i);
            i--;
        }
        else
        {
            // 计算当前使用哪个颜色
            int colorIndex = currentCount % blinkCount;
            int arrayIndex = colorIndex * 4; // 每个颜色占用4个数组位置
            
            if (arrayIndex + 3 < g_BlinkColors.Length)
            {
                int r = g_BlinkColors.Get(arrayIndex);
                int g = g_BlinkColors.Get(arrayIndex + 1);
                int b = g_BlinkColors.Get(arrayIndex + 2);
                int a = g_BlinkColors.Get(arrayIndex + 3);
                
                SafeSetEntityColor(door, r, g, b, a);
            }
        }
    }
    
    // 防止计数器溢出
    if (currentCount > 30000)
    {
        currentCount = 0;
    }
    currentCount++;
    
    //PrintToChatAll("正在闪烁 %d 扇门 (计数: %d)", g_BlinkingDoors.Length, currentCount);
    return Plugin_Continue;
}

public void Event_PlayerLeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    CPrintToChatAll("{default}本章节共有复活门{lightgreen}%d{default}扇", g_BlinkingDoors.Length);
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    // 获取死亡玩家的userid和实体索引
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    //PrintToChatAll("%d号玩家死亡", client);
    if (client != 0)
    {
        if (IsClientConnected(client) && GetClientTeam(client) == 2)
        {
            static Handle rescuetimeCvar = null;
            rescuetimeCvar = FindConVar("rescue_min_dead_time");
            int rescueTime = GetConVarInt(rescuetimeCvar);
            CPrintToChatAll("{default}本章节剩余复活门{lightgreen}%d{default}扇 救援等待时间{lightgreen}%d{default}秒", g_BlinkingDoors.Length, rescueTime);
        }
    }
    return Plugin_Continue;
}

public void Event_RescueDoorOpen(Event event, const char[] name, bool dontBroadcast)
{

    int doorEntity = event.GetInt("entindex");
    //PrintToChatAll("RescueDoorOpen doorEntity:%d", doorEntity);
    int find_entity = FindNearestEntity(doorEntity, "info_survivor_rescue");

    float pos[3];
    GetEntPropVector(find_entity, Prop_Data, "m_vecOrigin", pos);

    if(CheckPosition_FINALE(pos))
    {
        //PrintToChatAll("NAV_MESH_FINALE:Yes");
    }
    else
    {
        //PrintToChatAll("NAV_MESH_FINALE:No");
        int i = g_BlinkingDoors.FindValue(doorEntity);
        if (i != -1)
        {
            g_BlinkingDoors.Erase(i);
            EndDoorBlink(doorEntity);
        }
    }
    CPrintToChatAll("{default}复活门已被开启 本章节剩余复活门{lightgreen}%d{default}扇", g_BlinkingDoors.Length);
}

public Action Event_SurvivorRescued(Event event, const char[] name, bool dontBroadcast)
{
    //PrintToChatAll("救援事件触发");

    // 1. 获取victim的用户ID（UserID）
    int victimUserID = event.GetInt("victim");
    // 2. 将UserID转换为客户端索引
    int victimClient = GetClientOfUserId(victimUserID);
    //PrintToChatAll("victimClient:%d", victimClient);
    int find_entity_rescue = FindNearestEntity_client(victimClient, "info_survivor_rescue");
    int find_entity_door = FindNearestRescueDoorEntity(find_entity_rescue);

    float pos[3];
    GetEntPropVector(find_entity_rescue, Prop_Data, "m_vecOrigin", pos);

    if (CheckPosition_FINALE(pos))
    {
        //PrintToChatAll("NAV_MESH_FINALE:Yes");
        return Plugin_Continue;
    }
    else
    {
        //PrintToChatAll("NAV_MESH_FINALE:No");
        int i = g_BlinkingDoors.FindValue(find_entity_door);
        if (i == -1)
        {
            return Plugin_Continue;
        }
        else
        {
            g_BlinkingDoors.Erase(i);
            EndDoorBlink(find_entity_door);
        }
    }

    return Plugin_Continue;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        EndDoorBlink(g_BlinkingDoors.Get(i));
    }
    //PrintToChatAll("RoundEnd");
}

public Action Event_MapTransition(Handle:event, const String:name[], bool:dontBroadcast)
{
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        EndDoorBlink(g_BlinkingDoors.Get(i));
    }
    //PrintToChatAll("MapTransition");
    return Plugin_Continue;
}