#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <multicolors>
#define PLUGIN_VERSION "1.1.0"

#define MAX_SEARCH_DIST 1000   // 救援实体为圆心最大搜索距离
#define EXPAND_SEARCH_DIST 100  // 救援实体为圆心扩展搜索距离

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

/*
change log:
v1.1.0
    新增复活门每一轮闪烁的颜色根据复活门内能复活的玩家数量进行变动
    Added dynamic blink colors for rescue doors based on the number of rescuable players inside
	为所有非与门强关联的"info_survivor_rescue"实体创建点光源效果
	Create light source effects for all "info_survivor_rescue" entities not strongly associated with doors
    为复活门额外添加轮廓闪烁效果（一些门在手电照射时不会变色）
    Add additional outline blinking effects for rescue doors (some doors don't change color under flashlight)
    修复闪烁颜色会在非门实体上生效
    Fixed blinking colors affecting non-door entities
    优化闪烁逻辑，可重复使用的复活门被开启后依旧会闪烁
    Optimized blinking logic, reusable rescue doors continue blinking after being opened
    优化提示信息
    Improved notification messages
v1.0.0
	Initial Release
*/

int
    currentCount,
    g_TotalRescuePoints;    // 本章节救援点总数
// 通知冷却时间变量
float g_fLastNotifyTime[3] = {0.0, 0.0, 0.0}; // [0]=玩家死亡, [1]=门开启和救援事件共用, [2]=预留
#define NOTIFY_COOLDOWN 5.0  // 通知冷却时间(秒)
#define NOTIFY_DEATH 0
#define NOTIFY_DOOR_OPEN_OR_RESCUE 1  // 门开启和救援事件共用冷却时间
ArrayList
    g_BlinkingDoors,
    g_BlinkColors,    // 存储颜色数组
    g_RescueBeams,    // 存储救援点光源实体
    g_DoorEntityCounts; // 存储门实体和对应的关联次数（成对存储：实体ID，计数）
// 轮廓系统变量
int g_iOutlineIndex[2048] = {0};  // 存储每个实体对应的轮廓实体引用
Handle
    g_hTimer = null;
ConVar
    g_hBlinkSpeed,    // 闪烁速度（间隔时间）
    //g_hBlinkCount,    // 一轮闪烁的颜色数量
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
    //g_hBlinkCount = CreateConVar("l4d2_rescuedoor_blink_count", "3", "一轮闪烁的颜色数量 Number of colors in one blink cycle", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    g_hBlinkColors = CreateConVar("l4d2_rescuedoor_blink_colors", "255,0,0;255,255,0;0,255,0", "闪烁颜色列表(R,G,B格式，用分号分隔，共九个值) Blink colors list (R,G,B format, separated by semicolon, 9 values total)", FCVAR_NOTIFY);

    AutoExecConfig(true, "l4d2_rescuedoor_blink");

    g_BlinkingDoors = new ArrayList();
    g_BlinkColors = new ArrayList(3); // 存储RGB值，每个颜色3个值
    g_RescueBeams = new ArrayList(); // 存储救援点光源实体
    g_DoorEntityCounts = new ArrayList(2); // 存储门实体和计数（每个条目2个值：实体ID，计数）

    // 初始化颜色配置
    UpdateBlinkColors();
    
    // 当配置变量改变时更新颜色配置
    HookConVarChange(g_hBlinkColors, OnColorCvarChanged);
    HookConVarChange(g_hBlinkSpeed, OnBlinkSpeedChanged);

    // 添加调试命令
    RegConsoleCmd("sm_blink_reload", Command_ReloadBlinkConfig, "重新加载闪烁配置");
    RegConsoleCmd("sm_blink_info", Command_BlinkInfo, "显示当前闪烁配置信息");
    RegConsoleCmd("sm_test", Command_MyCommand, "测试指令");

    HookEvent("round_start_post_nav", Event_RoundStartPostNav, EventHookMode_PostNoCopy);
    HookEvent("player_left_safe_area", Event_PlayerLeftSafeArea);
    HookEvent("player_death", Event_PlayerDeath);
    HookEvent("rescue_door_open", Event_RescueDoorOpen);
    HookEvent("survivor_rescued", Event_SurvivorRescued);
    HookEvent("finale_start", Event_FinaleStart); // 最终章开始事件

    HookEvent("round_end", Event_RoundEnd);
    HookEvent("map_transition", Event_RoundEnd);//战役过关到下一关的时候 (没有触发round_end)
    HookEvent("mission_lost", Event_RoundEnd);//战役灭团重来该关卡的时候 (之后有触发round_end)
    HookEvent("finale_vehicle_leaving", Event_RoundEnd);//救援载具离开之时  (没有触发round_end)
}

public void OnMapStart()
{
    // 预缓存点光源所需的材质
    PrecacheModel("sprites/light_glow03_nofog.vmt", true);
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
    
    for (int i = 0; i < colorCount; i++)
    {
        char rgbParts[3][16];
        int rgbCount = ExplodeString(colorParts[i], ",", rgbParts, sizeof(rgbParts), sizeof(rgbParts[]));
        
        if (rgbCount == 3)
        {
            int r = StringToInt(rgbParts[0]);
            int g = StringToInt(rgbParts[1]);
            int b = StringToInt(rgbParts[2]);
            
            // 限制颜色值范围
            r = (r < 0) ? 0 : ((r > 255) ? 255 : r);
            g = (g < 0) ? 0 : ((g > 255) ? 255 : g);
            b = (b < 0) ? 0 : ((b > 255) ? 255 : b);
            
            g_BlinkColors.Push(r);
            g_BlinkColors.Push(g);
            g_BlinkColors.Push(b);
        }
    }
    
    // 如果没有有效颜色，使用默认颜色（RGB格式）
    if (g_BlinkColors.Length == 0)
    {
        // 默认红色
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(0);
        g_BlinkColors.Push(0);
        
        // 默认黄色
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(255);
        g_BlinkColors.Push(0);
        
        // 默认白色
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
    //int blinkCount = GetConVarInt(g_hBlinkCount);
    int colorCount = g_BlinkColors.Length / 3; // 每个颜色3个值(RGB)
    
    if (client > 0)
    {
        CPrintToChat(client, "{green}[闪烁插件]{default} 当前配置:");
        CPrintToChat(client, "  {lightgreen}闪烁速度:{default} {green}%.1f{default} 秒", blinkSpeed);
        //CPrintToChat(client, "  {lightgreen}配置颜色数:{default} {green}%d{default}", blinkCount);
        CPrintToChat(client, "  {lightgreen}解析颜色数:{default} {green}%d{default}", colorCount);
        CPrintToChat(client, "  {lightgreen}正在闪烁的门:{default} {green}%d{default}", g_BlinkingDoors.Length);
        
        // 显示颜色详情
        for (int i = 0; i < colorCount && i < 5; i++) // 最多显示5个颜色
        {
            int arrayIndex = i * 3; // RGB格式，每个颜色3个值
            int r = g_BlinkColors.Get(arrayIndex);
            int g = g_BlinkColors.Get(arrayIndex + 1);
            int b = g_BlinkColors.Get(arrayIndex + 2);
            CPrintToChat(client, "  {olive}颜色%d:{default} R={red}%d{default} G={olive}%d{default} B={blue}%d{default}", i + 1, r, g, b);
        }
        
        // 显示门实体计数信息
        CPrintToChat(client, "  {lightgreen}门实体计数记录:{default} {green}%d{default} 个", g_DoorEntityCounts.Length / 2);
        for (int i = 0; i < g_DoorEntityCounts.Length && i < 10; i += 2) // 最多显示5个门的计数
        {
            int doorEntity = g_DoorEntityCounts.Get(i);
            int count = g_DoorEntityCounts.Get(i + 1);
            CPrintToChat(client, "    {olive}门实体%d:{default} 被{green}%d{default}个救援点关联", doorEntity, count);
        }
    }
    else
    {
        PrintToServer("[闪烁插件] 当前配置:");
        PrintToServer("  闪烁速度: %.1f 秒", blinkSpeed);
        //PrintToServer("  配置颜色数: %d", blinkCount);
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
    
    // 获取实体类名
    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    
    // 只对指定的门类型进行颜色设置
    if (!StrEqual(classname, "func_door") && 
        !StrEqual(classname, "func_door_rotating") && 
        !StrEqual(classname, "prop_door_rotating") && 
        !StrEqual(classname, "prop_door_rotating_checkpoint"))
    {
        return;
    }
        
    // 检查实体是否支持渲染属性
    if (!HasEntProp(entity, Prop_Send, "m_nRenderMode"))
        return;
    
    // 先设置渲染模式，确保颜色能正确显示
    SetEntProp(entity, Prop_Send, "m_nRenderMode", 1); // kRenderTransColor
    
    // 安全地设置颜色
    if (HasEntProp(entity, Prop_Send, "m_clrRender"))
    {
        SetEntityRenderColor(entity, r, g, b, a);
    }
    
    // 确保实体可见
    if (HasEntProp(entity, Prop_Send, "m_fEffects"))
    {
        SetEntProp(entity, Prop_Send, "m_fEffects", GetEntProp(entity, Prop_Send, "m_fEffects") & ~32); // 移除EF_NODRAW
    }
    
    // 为门实体创建轮廓效果
    CreateEntityOutline(entity, r, g, b);
}

// 创建实体轮廓
void CreateEntityOutline(int entity, int r, int g, int b)
{
    if (!IsValidEntity(entity))
        return;

    if (!IfEntitySafeCheck(entity))
        return;

    // 如果轮廓已存在，只更新颜色
    int outlineEntity = g_iOutlineIndex[entity];
    if (IsValidEntRef(outlineEntity))
    {
        // 计算轮廓颜色值 (RGB转换为单个整数)
        int glowColor = r + (g * 256) + (b * 65536);
        SetEntProp(outlineEntity, Prop_Send, "m_glowColorOverride", glowColor);
        return;
    }
        
    // 获取实体模型
    char modelName[PLATFORM_MAX_PATH];
    char entityClassname[64];
    GetEntityClassname(entity, entityClassname, sizeof(entityClassname));
    
    // 特殊处理func_door_(rotating)实体
    if (StrEqual(entityClassname, "func_door_rotating") || StrEqual(entityClassname, "func_door"))
    {
        // func_door_rotating实体通常没有模型文件，使用默认门模型
        strcopy(modelName, sizeof(modelName), "models/props_doors/door_rotate_112.mdl");
    }
    else
    {
        // 其他实体正常获取模型
        if (!GetEntPropString(entity, Prop_Data, "m_ModelName", modelName, sizeof(modelName)))
            return;
    }
  
    // 创建轮廓实体
    outlineEntity = CreateEntityByName("prop_dynamic_override");
    
    // 设置轮廓实体的模型和属性
    DispatchKeyValue(outlineEntity, "model", modelName);
    DispatchKeyValue(outlineEntity, "targetname", "l4d2_rescuedoor_outline");
    
    DispatchSpawn(outlineEntity);
    
    // 如果是func_door_(rotating)实体，在生成后设置模型缩放
    if (StrEqual(entityClassname, "func_door_rotating") || StrEqual(entityClassname, "func_door"))
    {
        SetEntPropFloat(outlineEntity, Prop_Send, "m_flModelScale", 0.5); // 缩放为50%大小
    }
    
    // 获取原实体的位置和角度
    float pos[3], angles[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
    GetEntPropVector(entity, Prop_Send, "m_angRotation", angles);
    
    // 如果是func_door_rotating实体，调整Z轴坐标下移30个单位
    if (StrEqual(entityClassname, "func_door_rotating") || StrEqual(entityClassname, "func_door"))
    {
        pos[2] -= 30.0; // Z轴坐标下移30个单位
    }
    
    TeleportEntity(outlineEntity, pos, angles, NULL_VECTOR);
    
    // 设置轮廓发光属性
    SetEntProp(outlineEntity, Prop_Send, "m_CollisionGroup", 0);
    SetEntProp(outlineEntity, Prop_Send, "m_nSolidType", 0);
    SetEntProp(outlineEntity, Prop_Send, "m_nGlowRange", 500);
    SetEntProp(outlineEntity, Prop_Send, "m_iGlowType", 3);
    
    // 计算轮廓颜色值 (RGB转换为单个整数)
    int glowColor = r + (g * 256) + (b * 65536);
    SetEntProp(outlineEntity, Prop_Send, "m_glowColorOverride", glowColor);
    AcceptEntityInput(outlineEntity, "StartGlowing");
    
    // 设置轮廓实体不可见（只显示发光效果）
    SetEntityRenderMode(outlineEntity, RENDER_TRANSCOLOR);
    
    // 安全地设置轮廓实体颜色
    if (HasEntProp(outlineEntity, Prop_Send, "m_clrRender"))
    {
        SetEntityRenderColor(outlineEntity, 0, 0, 0, 0);
    }
    
    // 将轮廓实体绑定到原实体
    SetVariantString("!activator");
    AcceptEntityInput(outlineEntity, "SetParent", entity);
    
    // 存储轮廓实体引用
    g_iOutlineIndex[entity] = EntIndexToEntRef(outlineEntity);
    
    // 设置轮廓的传输钩子（只对生还者显示）
    SDKHook(outlineEntity, SDKHook_SetTransmit, Hook_SetTransmit_Outline);
}

// 删除实体轮廓
void RemoveEntityOutline(int entity)
{
    int outlineEntity = g_iOutlineIndex[entity];
    g_iOutlineIndex[entity] = 0;
    
    if (IsValidEntRef(outlineEntity))
        AcceptEntityInput(outlineEntity, "Kill");
}

// 清理g_BlinkingDoors中的门实体的轮廓
void ClearAllOutlines()
{
    // 清理g_BlinkingDoors中的门实体轮廓
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        int door = g_BlinkingDoors.Get(i);
        if (IsValidEntity(door) && g_iOutlineIndex[door] != 0)
        {
            RemoveEntityOutline(door);
        }
    }
}

// 检查实体引用是否有效
bool IsValidEntRef(int entity)
{
    if (entity && EntRefToEntIndex(entity) != INVALID_ENT_REFERENCE)
        return true;
    return false;
}

// 检查实体是否安全（参考item_hint.sp）
bool IfEntitySafeCheck(int entity)
{
    if (entity == -1) return false;
    
    char strClassname[64];
    if (!GetEntityClassname(entity, strClassname, sizeof(strClassname)))
        return false;
    
    // 排除func_door_rotating类型的实体
    // if (StrEqual(strClassname, "func_door_rotating"))
    //     return false;
        
    if (entity <= MaxClients || entity > 2048)
        return false;
        
    return true;
}

// 轮廓传输钩子 - 只对生还者显示
Action Hook_SetTransmit_Outline(int entity, int client)
{
    if (GetClientTeam(client) != 2) // 不是生还者团队
        return Plugin_Handled;
        
    return Plugin_Continue;
}

public void CheckPosition(float pos[3])
{
    // 使用left4dhooks API获取最近的导航区域
    Address area = L4D_GetNearestNavArea(pos, 220.0, true, false, false, 0);
    if (area == Address_Null)
        return;

    // 获取区域属性并检测
    int attributes = L4D_GetNavArea_SpawnAttributes(area);
    
    // 导航网格属性检查数组 - 属性名称和对应的标志位
    int navFlags[] = {
        NAV_MESH_EMPTY, NAV_MESH_STOP_SCAN, NAV_MESH_BATTLESTATION, NAV_MESH_FINALE,
        NAV_MESH_PLAYER_START, NAV_MESH_BATTLEFIELD, NAV_MESH_IGNORE_VISIBILITY, NAV_MESH_NOT_CLEARABLE,
        NAV_MESH_CHECKPOINT, NAV_MESH_OBSCURED, NAV_MESH_NO_MOBS, NAV_MESH_THREAT,
        NAV_MESH_RESCUE_VEHICLE, NAV_MESH_RESCUE_CLOSET, NAV_MESH_ESCAPE_ROUTE, NAV_MESH_DESTROYED_DOOR,
        NAV_MESH_NOTHREAT, NAV_MESH_LYINGDOWN
    };
    
    char navNames[][] = {
        "EMPTY", "STOP_SCAN", "BATTLESTATION", "FINALE",
        "PLAYER_START", "BATTLEFIELD", "IGNORE_VISIBILITY", "NOT_CLEARABLE", 
        "CHECKPOINT", "OBSCURED", "NO_MOBS", "THREAT",
        "RESCUE_VEHICLE", "RESCUE_CLOSET", "ESCAPE_ROUTE", "DESTROYED_DOOR",
        "NOTHREAT", "LYINGDOWN"
    };
    
    // 循环检查所有属性
    for (int i = 0; i < sizeof(navFlags); i++)
    {
        PrintToChatAll("%s: %d", navNames[i], (attributes & navFlags[i]) != 0 ? 1 : 0);
    }
    
    // 显示当前闪烁的救援门
    PrintToChatAll("当前闪烁的救援门数量: %d", g_BlinkingDoors.Length);
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        PrintToChatAll("RescueDoor[%d]: %d", i, g_BlinkingDoors.Get(i));
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
    "func_door",
    "func_door_rotating",
    "prop_door_rotating",
    "prop_door_rotating_checkpoint"
    };

    int nearestEntity = -1;
    float minDistance = -1.0;

    // 遍历所有门类型，找到最近的门实体
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
    
    // 如果没有找到任何门实体，返回-1
    if (nearestEntity == -1) return -1;
    
    // 检查找到的实体是否有m_isRescueDoor属性且等于1
    bool isValidRescueDoor = false;
    if (HasEntProp(nearestEntity, Prop_Send, "m_isRescueDoor"))
    {
        int isRescueDoor = GetEntProp(nearestEntity, Prop_Send, "m_isRescueDoor");
        if (isRescueDoor == 1)
        {
            isValidRescueDoor = true;
        }
    }
    
    // 如果找到的实体已经是有效的救援门，直接返回
    if (isValidRescueDoor)
    {
        return nearestEntity;
    }
    
    // 如果找到的实体不是有效救援门，在扩展范围内查找有效救援门
    float expandedDistance = minDistance + EXPAND_SEARCH_DIST;
    int validRescueDoor = -1;
    float validMinDistance = -1.0;
    
    // 在扩展范围内重新搜索有效救援门
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

            // 只在扩展范围内查找
            if (distance > expandedDistance) continue;
            
            // 检查是否有m_isRescueDoor属性且等于1
            if (HasEntProp(entity, Prop_Send, "m_isRescueDoor"))
            {
                int isRescueDoor = GetEntProp(entity, Prop_Send, "m_isRescueDoor");
                if (isRescueDoor == 1)
                {
                    // 找到有效救援门，更新最近距离
                    if (validMinDistance < 0 || distance < validMinDistance)
                    {
                        validMinDistance = distance;
                        validRescueDoor = entity;
                    }
                }
            }
        }
    }
    
    // 如果在扩展范围内找到了有效救援门，返回它；否则返回最初找到的实体
    return (validRescueDoor != -1) ? validRescueDoor : nearestEntity;
}

// bool PushUnique(ArrayList array, int value)
// {
//     if (array == null) return false;
    
//     // 检查是否已存在
//     if (array.FindValue(value) != -1) {
//         return false; // 已存在，不添加
//     }
    
//     // 添加新元素
//     array.Push(value);
//     return true;
// }

// 添加门实体到闪烁列表，并记录关联次数
bool AddDoorWithCount(int doorEntity)
{
    if (doorEntity == -1) return false;
    
    // 检查门是否已经在闪烁列表中
    int doorIndex = g_BlinkingDoors.FindValue(doorEntity);
    bool doorExists = (doorIndex != -1);
    
    // 如果门不在闪烁列表中，添加它
    if (!doorExists)
    {
        g_BlinkingDoors.Push(doorEntity);
    }
    
    // 查找门实体在计数数组中的位置
    int countIndex = -1;
    for (int i = 0; i < g_DoorEntityCounts.Length; i += 2)
    {
        if (g_DoorEntityCounts.Get(i) == doorEntity)
        {
            countIndex = i;
            break;
        }
    }
    
    if (countIndex != -1)
    {
        // 门实体已存在，增加计数
        int doorCurrentCount = g_DoorEntityCounts.Get(countIndex + 1);
        g_DoorEntityCounts.Set(countIndex + 1, doorCurrentCount + 1);
    }
    else
    {
        // 门实体不存在，添加新记录
        g_DoorEntityCounts.Push(doorEntity);
        g_DoorEntityCounts.Push(1); // 初始计数为1
    }
    
    return !doorExists; // 返回是否是新添加的门
}

// 获取门实体的关联次数
// int GetDoorCount(int doorEntity)
// {
//     for (int i = 0; i < g_DoorEntityCounts.Length; i += 2)
//     {
//         if (g_DoorEntityCounts.Get(i) == doorEntity)
//         {
//             return g_DoorEntityCounts.Get(i + 1);
//         }
//     }
//     return 0; // 未找到返回0
// }

// 获取门实体的关联次数
int GetDoorCount(int doorEntity)
{
    for (int i = 0; i < g_DoorEntityCounts.Length; i += 2)
    {
        if (g_DoorEntityCounts.Get(i) == doorEntity)
        {
            return g_DoorEntityCounts.Get(i + 1);
        }
    }
    return 0; // 未找到返回0
}

// 减少门实体的关联次数，返回减少后的计数值
int DecreaseDoorCount(int doorEntity)
{
    for (int i = 0; i < g_DoorEntityCounts.Length; i += 2)
    {
        if (g_DoorEntityCounts.Get(i) == doorEntity)
        {
            int doorCurrentCount = g_DoorEntityCounts.Get(i + 1);
            if (doorCurrentCount > 0)
            {
                // 检查门实体是否有m_isRescueDoor属性
                if (HasEntProp(doorEntity, Prop_Send, "m_isRescueDoor"))
                {
                    // 获取m_isRescueDoor属性的值
                    int isRescueDoor = GetEntProp(doorEntity, Prop_Send, "m_isRescueDoor");
                    if (isRescueDoor == 1)
                    {
                        // m_isRescueDoor为1，计数减1
                        doorCurrentCount--;
                    }
                    else if (isRescueDoor == 0)
                    {
                        // m_isRescueDoor为0，计数清零
                        doorCurrentCount = 0;
                    }
                }
                else
                {
                    // 没有m_isRescueDoor属性，按原逻辑减1
                    doorCurrentCount--;
                }
                
                g_DoorEntityCounts.Set(i + 1, doorCurrentCount);
                
                // 如果计数为0，从数组中移除这个记录
                if (doorCurrentCount == 0)
                {
                    g_DoorEntityCounts.Erase(i); // 移除门实体ID
                    g_DoorEntityCounts.Erase(i); // 移除计数值
                }
                
                return doorCurrentCount;
            }
            break;
        }
    }
    return 0; // 未找到或计数已为0
}

// 清理门实体计数数组
void ClearDoorCounts()
{
    g_DoorEntityCounts.Clear();
}

public void EndDoorBlink(int door)
{
    if (!IsValidEntity(door)) return;
    
    // 获取实体类名
    char classname[64];
    GetEntityClassname(door, classname, sizeof(classname));
    
    // 只对指定的门类型进行颜色恢复
    if (StrEqual(classname, "func_door") || 
        StrEqual(classname, "func_door_rotating") || 
        StrEqual(classname, "prop_door_rotating") || 
        StrEqual(classname, "prop_door_rotating_checkpoint"))
    {
        // 安全地恢复默认颜色和渲染模式
        if (HasEntProp(door, Prop_Send, "m_clrRender"))
        {
            SetEntityRenderColor(door, 255, 255, 255, 255);
        }
        
        // 检查实体是否有m_nRenderMode属性再设置
        if (HasEntProp(door, Prop_Send, "m_nRenderMode"))
        {
            SetEntProp(door, Prop_Send, "m_nRenderMode", 0); // kRenderNormal
        }
    }
}

// 创建救援点光源 - 只创建点光源指示
int CreateRescueBeam(float pos[3])
{
    // 创建点光源作为救援点指示
    int sprite = CreateEntityByName("env_sprite");
    if (sprite == -1) return -1;
    
    DispatchKeyValue(sprite, "model", "sprites/light_glow03_nofog.vmt");
    DispatchKeyValue(sprite, "rendercolor", "255 255 0");
    DispatchKeyValue(sprite, "renderamt", "200");
    DispatchKeyValue(sprite, "rendermode", "9");
    DispatchKeyValue(sprite, "scale", "1.2");
    DispatchKeyValue(sprite, "spawnflags", "1");
    DispatchKeyValue(sprite, "framerate", "10");
    DispatchKeyValue(sprite, "HDRColorScale", "1.0");
    DispatchKeyValue(sprite, "GlowProxySize", "4.0");
    
    float spritePos[3];
    spritePos[0] = pos[0];
    spritePos[1] = pos[1];
    spritePos[2] = pos[2] + 5.0; // 点光源位置
    
    TeleportEntity(sprite, spritePos, NULL_VECTOR, NULL_VECTOR);
    DispatchSpawn(sprite);
    
    // 只存储点光源实体
    g_RescueBeams.Push(sprite);
    
    return sprite;
}

// 清理救援点光源
void ClearRescueBeams()
{
    for (int i = 0; i < g_RescueBeams.Length; i++)
    {
        int sprite = g_RescueBeams.Get(i);
        if (IsValidEntity(sprite)) AcceptEntityInput(sprite, "Kill");
    }
    g_RescueBeams.Clear();
}

// 删除指定位置附近的救援点光源
void RemoveRescueBeamNearPosition(float targetPos[3], float maxDistance)
{
    for (int i = 0; i < g_RescueBeams.Length; i++)
    {
        int sprite = g_RescueBeams.Get(i);
        
        if (IsValidEntity(sprite))
        {
            float beamPos[3];
            GetEntPropVector(sprite, Prop_Send, "m_vecOrigin", beamPos);
            
            // 计算距离
            float distance = GetVectorDistance(targetPos, beamPos);
            
            if (distance <= maxDistance)
            {
                // 找到了需要删除的点光源
                AcceptEntityInput(sprite, "Kill");
                
                // 从数组中移除
                g_RescueBeams.Erase(i);
                
                //CPrintToChatAll("{olive}[救援提示]{default} 救援点点光源已移除 (距离: {green}%.1f{default})", distance);
                return; // 只删除最近的一个点光源
            }
        }
    }
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
    g_TotalRescuePoints = 0;  // 重置救援点计数
    
    if (g_hTimer != null)
    {
        CloseHandle(g_hTimer); // 停止计时器
        g_hTimer = null;
    }
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        EndDoorBlink(g_BlinkingDoors.Get(i));
    }
    g_BlinkingDoors.Clear();
    
    // 清理之前的救援点光源
    ClearRescueBeams();
    
    // 清理门实体计数记录
    ClearDoorCounts();

    int entity = -1;
    int find_entity = -1;
    float origin[3];
    
    // 统计info_survivor_rescue实体总数
    while ((entity = FindEntityByClassname(entity, "info_survivor_rescue")) != -1)
    {
        g_TotalRescuePoints++;  // 统计救援点总数
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);

        if (CheckPosition_RESCUE_CLOSET(origin))
        {
            //PrintToChatAll("NAV_MESH_RESCUE_CLOSET:Yes");
            find_entity = FindNearestRescueDoorEntity(entity);
            if (find_entity != -1)
            {
                // 找到了救援门
                if (HasEntProp(find_entity, Prop_Send, "m_isRescueDoor"))
                {
                    int isRescueDoor = GetEntProp(find_entity, Prop_Send, "m_isRescueDoor");
                    if (isRescueDoor == 1)
                    {
                        //bool isNewDoor = AddDoorWithCount(find_entity);
                        AddDoorWithCount(find_entity);
                        //int doorCount = GetDoorCount(find_entity);
                        //CPrintToChatAll("{olive}[救援提示]{default} 标准救援门实体%d被%d个救援点关联 (新门:%s)", find_entity, doorCount, isNewDoor ? "是" : "否");
                    }
                    else
                    {
                        //创建非标准救援门，救援实体的点光源
                        CreateRescueBeam(origin);
                        //CPrintToChatAll("{olive}[救援提示]{default} 在救援点 {green}%.1f %.1f %.1f{default} 创建了点光源指示", origin[0], origin[1], origin[2]);
                    }
                }
                else
                {
                    //bool isNewDoor = AddDoorWithCount(find_entity);
                    AddDoorWithCount(find_entity);
                    //int doorCount = GetDoorCount(find_entity);
                    //CPrintToChatAll("{olive}[救援提示]{default} func_door实体%d被%d个救援点关联 (新门:%s)", find_entity, doorCount, isNewDoor ? "是" : "否");

                    //创建func_door，救援实体的点光源
                    CreateRescueBeam(origin);
                    //CPrintToChatAll("{olive}[救援提示]{default} 在救援点 {green}%.1f %.1f %.1f{default} 创建了点光源指示", origin[0], origin[1], origin[2]);
                }
            }
            else
            {
                // 没有找到救援门，创建点光源指示救援点位置
                CreateRescueBeam(origin);
                //CPrintToChatAll("{olive}[救援提示]{default} 在救援点 {green}%.1f %.1f %.1f{default} 创建了点光源指示", origin[0], origin[1], origin[2]);
            }
            
        }
        else
        {
            //PrintToChatAll("NAV_MESH_RESCUE_CLOSET:No");
        }
    }
    
    // 输出统计信息
    //CPrintToChatAll("{olive}[救援统计]{default} 本章节共发现 {green}%d{default} 个救援点，创建 {green}%d{default} 个点光源指示", g_TotalRescuePoints, g_RescueBeams.Length);
    
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
    
    int colorCount = g_BlinkColors.Length / 3; // 每个颜色3个值(RGB)
    
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
            // 获取实体类名，确保只对指定的门类型进行闪烁
            char classname[64];
            GetEntityClassname(door, classname, sizeof(classname));
            
            // 只对指定的门类型进行闪烁操作
            if (!StrEqual(classname, "func_door") && 
                !StrEqual(classname, "func_door_rotating") && 
                !StrEqual(classname, "prop_door_rotating") && 
                !StrEqual(classname, "prop_door_rotating_checkpoint"))
            {
                continue;
            }
            
            // 获取门的计数，决定闪烁模式
            int doorCount = GetDoorCount(door);
            if (doorCount <= 0) continue; // 如果计数为0或无效，跳过
            
            // 限制计数在1-3之间
            doorCount = (doorCount > 3) ? 3 : doorCount;
            
            // 根据门计数确定一轮闪烁的总步数（计数颜色+白色）
            int totalSteps = doorCount + 1;
            int currentStep = currentCount % totalSteps;
            
            int r, g, b;
            
            if (currentStep < doorCount)
            {
                // 显示对应计数的颜色之一
                int colorIndex = currentStep % colorCount; // 循环使用可用颜色
                int arrayIndex = colorIndex * 3;
                
                if (arrayIndex + 2 < g_BlinkColors.Length)
                {
                    r = g_BlinkColors.Get(arrayIndex);
                    g = g_BlinkColors.Get(arrayIndex + 1);
                    b = g_BlinkColors.Get(arrayIndex + 2);
                }
                else
                {
                    // 默认红色
                    r = 255; g = 0; b = 0;
                }
            }
            else
            {
                // 最后一步显示白色（无色）
                r = 255; g = 255; b = 255;
            }
            
            SafeSetEntityColor(door, r, g, b, 255); // Alpha固定为255
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

// 延迟救援通知的回调函数
public Action Timer_RescueNotification(Handle timer)
{
    CPrintToChatAll("{default}救援事件触发 本章节剩余复活门{lightgreen}%d{default}扇 剩余标记的救援点实体{lightgreen}%d{default}个", g_BlinkingDoors.Length, g_RescueBeams.Length);
    return Plugin_Continue;
}

public void Event_PlayerLeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    CPrintToChatAll("{default}本章节共有复活门{lightgreen}%d{default}扇 救援点实体{lightgreen}%d{default}个 其中标记的救援点实体共有{lightgreen}%d{default}个", g_BlinkingDoors.Length, g_TotalRescuePoints, g_RescueBeams.Length);
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    // 获取死亡玩家的userid和实体索引
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    // 验证客户端有效性
    if (client <= 0 || client > MaxClients)
        return Plugin_Continue;
    
    // 验证客户端是否在游戏中
    if (!IsClientConnected(client) || !IsClientInGame(client))
        return Plugin_Continue;
    
    // 验证是否为生还者团队
    if (GetClientTeam(client) != 2)
        return Plugin_Continue;
    
    // 检查通知冷却时间
    float currentTime = GetGameTime();
    if (FloatAbs(currentTime - g_fLastNotifyTime[NOTIFY_DEATH]) >= NOTIFY_COOLDOWN)
    {
        // 获取救援时间ConVar
        ConVar rescuetimeCvar = FindConVar("rescue_min_dead_time");
        int rescueTime = (rescuetimeCvar != null) ? rescuetimeCvar.IntValue : 30;
        
        // 发送复活门通知
        CPrintToChatAll("{default}本章节剩余复活门{lightgreen}%d{default}扇 剩余标记的救援点实体{lightgreen}%d{default}个 救援等待时间{lightgreen}%d{default}秒", 
                        g_BlinkingDoors.Length, g_RescueBeams.Length, rescueTime);
        
        // 更新最后通知时间
        g_fLastNotifyTime[NOTIFY_DEATH] = currentTime;
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
            RemoveEntityOutline(doorEntity);
        }
    }
    
    // 检查通知冷却时间
    float currentTime = GetGameTime();
    if (FloatAbs(currentTime - g_fLastNotifyTime[NOTIFY_DOOR_OPEN_OR_RESCUE]) >= NOTIFY_COOLDOWN)
    {
        CPrintToChatAll("{default}复活门已被开启 本章节剩余复活门{lightgreen}%d{default}扇 剩余标记的救援点实体{lightgreen}%d{default}个", g_BlinkingDoors.Length, g_RescueBeams.Length);
        g_fLastNotifyTime[NOTIFY_DOOR_OPEN_OR_RESCUE] = currentTime; // 更新最后通知时间
    }
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
    
    // 获取救援点位置并删除该位置的点光源（如果存在）
    float rescuePos[3];
    GetEntPropVector(find_entity_rescue, Prop_Data, "m_vecOrigin", rescuePos);
    RemoveRescueBeamNearPosition(rescuePos, 100.0); // 在100单位范围内查找并删除点光源
    
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
        
        // 减少门实体的计数
        int remainingCount = DecreaseDoorCount(find_entity_door);
        
        // 如果计数减少后为0，则执行闪烁删除
        if (remainingCount == 0)
        {
            int i = g_BlinkingDoors.FindValue(find_entity_door);
            if (i != -1)
            {
                g_BlinkingDoors.Erase(i);
                EndDoorBlink(find_entity_door);
                RemoveEntityOutline(find_entity_door);
            }
        }
    }

    // 检查通知冷却时间
    float currentTime = GetGameTime();
    if (FloatAbs(currentTime - g_fLastNotifyTime[NOTIFY_DOOR_OPEN_OR_RESCUE]) >= NOTIFY_COOLDOWN)
    {
        // 延迟3秒执行通知
        CreateTimer(3.0, Timer_RescueNotification, _, _);
        g_fLastNotifyTime[NOTIFY_DOOR_OPEN_OR_RESCUE] = currentTime; // 更新最后通知时间
    }

    return Plugin_Continue;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // 停止闪烁计时器
    if (g_hTimer != null)
    {
        CloseHandle(g_hTimer);
        g_hTimer = null;
    }

    // 清理所有闪烁的门（包括颜色恢复和轮廓清理）
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        EndDoorBlink(g_BlinkingDoors.Get(i));
    }
    
    //先清理救援门轮廓（以标记为索引）
    ClearAllOutlines();

    // 清理所有救援门标记
    g_BlinkingDoors.Clear();

    // 清理救援点光源
    ClearRescueBeams();
    
    // 清理门实体计数记录
    ClearDoorCounts();
    
    //PrintToChatAll("RoundEnd");
}

// 最终章开始事件 - 清除所有救援门标记
public void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    // 停止闪烁计时器
    if (g_hTimer != null)
    {
        CloseHandle(g_hTimer);
        g_hTimer = null;
    }
    
    // 恢复所有救援门的默认颜色
    for (int i = 0; i < g_BlinkingDoors.Length; i++)
    {
        EndDoorBlink(g_BlinkingDoors.Get(i));
    }

    //先清理救援门轮廓（以标记为索引）
    ClearAllOutlines();
    
    // 清理所有救援门标记
    g_BlinkingDoors.Clear();
    
    // 清理救援点光源
    ClearRescueBeams();
    
    // 清理门实体计数记录
    ClearDoorCounts();
    
    // 通知玩家最终章开始，救援门失效
    CPrintToChatAll("{default}章节救援开始！所有复活门及救援实体已{lightgreen}失效");
}