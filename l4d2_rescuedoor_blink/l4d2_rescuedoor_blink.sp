#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#pragma newdecls required
#define PLUGIN_VERSION "1.4.0"

#define MAX_SEARCH_DIST 600   // 救援实体为圆心最大搜索距离

#define NAV_MESH_FINALE 64
#define NAV_MESH_RESCUE_CLOSET 65536
#define NAV_SPAWN_DESTROYED_DOOR 262144

// 默认用于 info_survivor_rescue 轮廓的模型
#define DEFAULT_RESCUE_MODEL "models/props_unique/airport/atlas_break_ball.mdl"


public Plugin myinfo = 
{
	name = "l4d2_rescuedoor_blink",
	author = "maluQxzh",
	description = "Make rescue doors blink with customizable colors and timing",
	version = PLUGIN_VERSION,
	url = "https://github.com/maluQxzh/L4D2_Plugins"
}

/*
change log:
v1.4.0
    针对一个复活房间里有4个救援点实体但只有一扇复活门和一个厕所里有一个以上救援点实体的特殊情况进行了优化
    现在搜索处理逻辑基本符合游戏本身逻辑
    Optimized for special cases where a rescue room has 4 rescue point entities but only one rescue door, or a restroom has more than one rescue point entity
    The search processing logic now basically matches the game's own logic
v1.3.0
    优化复活门搜索逻辑
    新增排除假救援点，现在假救援点不再进行任何标记
    新增针对标记救援点的复活提示，当有玩家处于影响死亡玩家复活的救援点范围内时，会收到提示信息
    新增一系列ConVar配置
    Optimized rescue door search logic
    Added exclusion for fake rescue points, which are no longer marked
    Added rescue notification for marked rescue points, players within the range of rescue points affecting dead player revival will receive notification messages
    Added a series of ConVar configurations
v1.2.2
    优化复活门搜索逻辑
    Optimized rescue door search logic
v1.2.1
    优化复活门搜索逻辑
    优化提示信息
    移除对<multicolors>的依赖
    Optimized rescue door search logic
    Improved notification messages
    Removed dependency on <multicolors> (now using native chat color codes)
v1.2.0
    重构大部分代码
    创建点光源效果改为穿透发光的圆形轮廓，不再处理funcdoor类型门，只处理prop_door_rotating和prop_door_rotating_checkpoint类型门
    搜索复活点实体周围的救援门时,增加了对门与复活点之间以rescuecloset网格属性的连通性的检查
    Refactored most of the code
    Changed light source effects to glowing circular outlines, no longer processing func_door type doors, only handling prop_door_rotating and prop_door_rotating_checkpoint type doors
    Added connectivity check via rescue closet nav mesh attributes between doors and rescue points when searching for rescue doors around rescue point entities
v1.1.0
    新增复活门每一轮闪烁的颜色根据复活门内能复活的玩家数量进行变动
	为所有非与门强关联的"info_survivor_rescue"实体创建点光源效果
    为复活门额外添加轮廓闪烁效果（一些门在手电照射时不会变色）
    修复闪烁颜色会在非门实体上生效
    优化闪烁逻辑，可重复使用的复活门被开启后依旧会闪烁
    优化提示信息
    Added dynamic blink colors for rescue doors based on the number of rescuable players inside
    Create light source effects for all "info_survivor_rescue" entities not strongly associated with doors
    Add additional outline blinking effects for rescue doors (some doors don't change color under flashlight)
    Fixed blinking colors affecting non-door entities
    Optimized blinking logic, reusable rescue doors continue blinking after being opened
    Improved notification messages
v1.0.0
	Initial Release
*/

/*
游戏中复活机制详解：

    救援实体知识：
    1.每个复活点实体可以复活一位玩家，复活点实体失效条件：
        a. 当前复活点实体复活了一位玩家
        b. 复活点所关联的复活门被开启
    
    游戏中的标记复活门的逻辑：
    1.以当前复活点实体为中心所在导航区域向外扩展（单向连通即可）一定距离（具体未知），将相应导航区域标记为“NAV_MESH_RESCUE_CLOSET”，当扩展到含有“NAV_SPAWN_DESTROYED_DOOR”属性的导航区域时停止扩展，并将该区域内的门标记为复活门（"m_isRescueDoor"=1）
        若同时遇到多个含有“NAV_SPAWN_DESTROYED_DOOR”属性的导航区域，则同时将该区域内的门标记为复活门，即救援点实体关联了多个复活门
    2.若上述操作在扩展到最大距离时仍没有遇到含有“NAV_SPAWN_DESTROYED_DOOR”属性的导航区域，则该复活点实体不关联任何复活门

    一些疑问：
    无效的救援实体是怎么产生的的？（游戏中有些救援实体无法复活玩家）
        从外侧的导航区域（非“NAV_MESH_RESCUE_CLOSET”）出发，无法连通到该救援实体所在的导航区域，被判定为不可达（无法进入救援玩家）
    超过了救援等待时间，为什么救援点还是无法复活玩家？
        有玩家处于该救援点实体扩展出的“NAV_MESH_RESCUE_CLOSET”区域内，阻止了该救援点的生成待复活玩家的呼救（表现为不复活）

    结论：
    1. 若救援点实体关联到复活门，插件会用颜色标记该复活门，同时用颜色数量提示被关联的救援点实体的个数，当复活门开启时，被关联的救援点不管是否已经复活玩家都会失效
    2. 若救援点实体未关联到任何复活门，则该救援点实体会被插件标记，每个被标记的救援点都可以复活一位玩家
*/

int
    g_iCurrentCount,
    g_iTotalRescuePoints;    // 本章节救援点总数
float
    g_fLastNotifyTime;

ArrayList
    g_aBlinkingDoors,  // 存储所有被标记的复活门实体
    g_aBlinkingRescue, // 存储所有被标记的救援点实体
    g_aBlinkColors,    // 存储颜色数组
    g_aDoorEntityCounts, // 存储门实体和对应的关联次数（成对存储：实体ID，计数）
    g_aRescueEntities, // 储存所有救援点实体
    g_aRescueGroups,   // 救援点实体分组
    g_aGroupHasDoor;   // 分组是否有标准救援门
// 轮廓系统变量
int g_iOutlineIndex[2048] = {0};  // 存储每个实体对应的轮廓实体引用
Handle
    g_hTimer = null,
    g_hRescueStartTimer[MAXPLAYERS + 1],
    g_hRescueRepeatTimer[MAXPLAYERS + 1];
ConVar
    g_hBlinkSpeed,    // 闪烁速度（间隔时间）
    g_hBlinkColors,   // 颜色字符串（RGB值）
    g_hOutlineGlowRange, // 轮廓发光可见范围（默认500）
    g_hRescueModelPath, // 自定义 info_survivor_rescue 的模型路径
    g_hRescuePointColor, // 标记救援点轮廓颜色（R,G,B）
    g_hRescueScalePercent, // info_survivor_rescue 轮廓模型缩放百分比
    g_hRescueZOffset;   // info_survivor_rescue 轮廓模型的Z轴下移偏移量
    

char g_sRescueModel[PLATFORM_MAX_PATH]; // 实际使用的模型路径
int g_iRescueColor[3] = {0, 255, 0}; // 标记救援点轮廓默认颜色（绿色）
int g_iDoorGroup[2048]; // 存储每个门实体所属的组ID

public void OnPluginStart()
{
    char game_name[64];
    GetGameFolderName(game_name, sizeof(game_name));
    if (!StrEqual(game_name, "left4dead2", false))
        SetFailState("Plugin supports Left 4 Dead 2 only.");

    CreateConVar("l4d2_rescuedoor_blink_version", PLUGIN_VERSION, "l4d2_rescuedoor_blink version", FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD);

    // 创建配置变量
    g_hBlinkSpeed = CreateConVar("l4d2_rescuedoor_blink_speed", "1.0", "闪烁间隔时间（秒）Blink interval time (seconds)", FCVAR_NOTIFY, true, 0.1, true, 10.0);
    g_hBlinkColors = CreateConVar("l4d2_rescuedoor_blink_colors",
        "255,0,0;255,255,0;0,255,0",
        "闪烁颜色列表(R,G,B格式，用分号分隔，共九个值) Blink colors list (R,G,B format, separated by semicolon, 9 values total)",
        FCVAR_NOTIFY
    );
    g_hOutlineGlowRange = CreateConVar(
        "l4d2_rescuedoor_blink_glow_range",
        "500",
        "轮廓发光可见范围（单位：Hammer单位）",
        FCVAR_NOTIFY,
        true, 100.0,
        true, 3000.0
    );
    g_hRescueModelPath = CreateConVar(
        "l4d2_rescuedoor_blink_rescue_model",
        "models/props_unique/airport/atlas_break_ball.mdl",
        "用于标记救援点所使用的模型路径（留空或无效将使用默认）",
        FCVAR_NOTIFY
    );
    g_hRescuePointColor = CreateConVar(
        "l4d2_rescuedoor_blink_rescue_color",
        "0,255,0",
        "用于标记救援点所使用的模型的外轮廓颜色（R,G,B）",
        FCVAR_NOTIFY
    );
    g_hRescueScalePercent = CreateConVar(
        "l4d2_rescuedoor_blink_rescue_scale_percent",
        "15",
        "用于标记救援点所使用的模型缩放百分比（1-300）",
        FCVAR_NOTIFY,
        true, 1.0,
        true, 300.0
    );
    g_hRescueZOffset = CreateConVar(
        "l4d2_rescuedoor_blink_rescue_zoffset",
        "-20.0",
        "用于标记救援点所使用的模型的Z轴移偏移量（单位：Hammer单位；正值为上移）",
        FCVAR_NOTIFY
    );

    AutoExecConfig(true, "l4d2_rescuedoor_blink");

    g_fLastNotifyTime = GetGameTime();
    g_aBlinkingDoors = new ArrayList();
    g_aBlinkingRescue = new ArrayList();
    g_aBlinkColors = new ArrayList(3); // 存储RGB值，每个颜色3个值
    g_aDoorEntityCounts = new ArrayList(2); // 存储门实体和计数（每个条目2个值：实体ID，计数）
    g_aRescueEntities = new ArrayList();
    g_aRescueGroups = new ArrayList();
    g_aGroupHasDoor = new ArrayList();
    
    for(int i=0; i<2048; i++) g_iDoorGroup[i] = -1;

    // 初始化颜色配置
    UpdateBlinkColors();
    // 初始化救援点外轮廓颜色（R,G,B），避免首图未读到
    UpdateRescuePointColor();
    
    // 当配置变量改变时更新颜色配置
    HookConVarChange(g_hBlinkColors, OnColorCvarChanged);
    HookConVarChange(g_hBlinkSpeed, OnBlinkSpeedChanged);

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

// 预缓存用于轮廓的模型，优先使用 ConVar 配置，失败则使用默认，避免 late precache 提示
public void OnMapStart()
{
    // 先设置默认
    strcopy(g_sRescueModel, sizeof(g_sRescueModel), DEFAULT_RESCUE_MODEL);

    char cfgPath[PLATFORM_MAX_PATH];
    if (g_hRescueModelPath != null)
        GetConVarString(g_hRescueModelPath, cfgPath, sizeof(cfgPath));
    else
        cfgPath[0] = '\0';

    // 如果配置不为空，尝试预缓存自定义模型
    if (cfgPath[0] != '\0')
    {
        int idx = PrecacheModel(cfgPath, true);
        if (idx > 0)
            strcopy(g_sRescueModel, sizeof(g_sRescueModel), cfgPath);
        else
        {
            PrecacheModel(DEFAULT_RESCUE_MODEL, true);
            strcopy(g_sRescueModel, sizeof(g_sRescueModel), DEFAULT_RESCUE_MODEL);
        }
    }
    else
        PrecacheModel(DEFAULT_RESCUE_MODEL, true);
}

// 解析颜色配置字符串
void UpdateBlinkColors()
{
    g_aBlinkColors.Clear();
    
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
            
            g_aBlinkColors.Push(r);
            g_aBlinkColors.Push(g);
            g_aBlinkColors.Push(b);
        }
    }
    
    // 如果没有有效颜色，使用默认颜色（RGB格式）
    if (g_aBlinkColors.Length == 0)
    {
        // 默认红色
    g_aBlinkColors.Push(255);
    g_aBlinkColors.Push(0);
    g_aBlinkColors.Push(0);
        
        // 默认黄色
    g_aBlinkColors.Push(255);
    g_aBlinkColors.Push(255);
    g_aBlinkColors.Push(0);
        
        // 默认白色
    g_aBlinkColors.Push(255);
    g_aBlinkColors.Push(255);
    g_aBlinkColors.Push(255);
    }
}

// 解析用于标记救援点的外轮廓颜色（R,G,B）到 g_iRescueColor
void UpdateRescuePointColor()
{
    // 默认绿色
    g_iRescueColor[0] = 0;
    g_iRescueColor[1] = 255;
    g_iRescueColor[2] = 0;

    if (g_hRescuePointColor == null)
        return;

    char colorStr[64];
    GetConVarString(g_hRescuePointColor, colorStr, sizeof(colorStr));

    char parts[3][16];
    int cnt = ExplodeString(colorStr, ",", parts, sizeof(parts), sizeof(parts[]));
    if (cnt == 3)
    {
        int r = StringToInt(parts[0]);
        int g = StringToInt(parts[1]);
        int b = StringToInt(parts[2]);

        // clamp 0-255
        r = (r < 0) ? 0 : ((r > 255) ? 255 : r);
        g = (g < 0) ? 0 : ((g > 255) ? 255 : g);
        b = (b < 0) ? 0 : ((b > 255) ? 255 : b);

        g_iRescueColor[0] = r;
        g_iRescueColor[1] = g;
        g_iRescueColor[2] = b;
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
        if (IsValidHandle(g_hTimer))
            delete g_hTimer;
        g_hTimer = null;
        
        float blinkSpeed = GetConVarFloat(g_hBlinkSpeed);
        g_hTimer = CreateTimer(blinkSpeed, Timer_DoorBlink, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    }
}

// 判断实体是否是救援门
bool IsRescueDoor(int entity)
{
    return HasEntProp(entity, Prop_Send, "m_isRescueDoor") && GetEntProp(entity, Prop_Send, "m_isRescueDoor") == 1;
}

// 安全地设置实体颜色和渲染模式
void SafeSetEntityColor(int entity, int r, int g, int b, int a)
{
    if (!HasEntProp(entity, Prop_Send, "m_isRescueDoor"))
        return;

    if (HasEntProp(entity, Prop_Send, "m_clrRender"))
        SetEntityRenderColor(entity, r, g, b, a);
    
    CreateEntityOutline(entity, r, g, b);
}

// 创建实体轮廓
void CreateEntityOutline(int entity, int r, int g, int b)
{
    if (!IsValidEntity(entity))
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

    // 特殊处理救援点实体：优先使用配置/预缓存成功的模型
    if (StrEqual(entityClassname, "info_survivor_rescue"))
        strcopy(modelName, sizeof(modelName), g_sRescueModel[0] ? g_sRescueModel : DEFAULT_RESCUE_MODEL);
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

    // 如果是info_survivor_rescue实体，在生成后设置模型缩放（由百分比ConVar控制）
    if (StrEqual(entityClassname, "info_survivor_rescue"))
    {
        float fScale = 0.15; // 默认15%
        if (g_hRescueScalePercent != null)
        {
            int p = GetConVarInt(g_hRescueScalePercent);
            if (p < 1) p = 1;
            if (p > 300) p = 300;
            fScale = float(p) / 100.0;
        }
        SetEntPropFloat(outlineEntity, Prop_Send, "m_flModelScale", fScale);
    }
    
    // 获取原实体的位置和角度
    float pos[3], angles[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
    GetEntPropVector(entity, Prop_Send, "m_angRotation", angles);

    // 如果是info_survivor_rescue实体，按配置调整Z轴坐标下移（默认20.0）
    if (StrEqual(entityClassname, "info_survivor_rescue"))
    {
        float g_fRescueZOffset = g_hRescueZOffset != null ? GetConVarFloat(g_hRescueZOffset) : -20.0;
        pos[2] += g_fRescueZOffset;
    }

    TeleportEntity(outlineEntity, pos, angles, NULL_VECTOR);
    
    // 设置轮廓发光属性
    SetEntProp(outlineEntity, Prop_Send, "m_CollisionGroup", 0);
    SetEntProp(outlineEntity, Prop_Send, "m_nSolidType", 0);
    int iGlowRange = (g_hOutlineGlowRange != null) ? GetConVarInt(g_hOutlineGlowRange) : 500;
    SetEntProp(outlineEntity, Prop_Send, "m_nGlowRange", iGlowRange);
    SetEntProp(outlineEntity, Prop_Send, "m_iGlowType", 3);
    
    // 计算轮廓颜色值 (RGB转换为单个整数)
    int glowColor = r + (g * 256) + (b * 65536);
    SetEntProp(outlineEntity, Prop_Send, "m_glowColorOverride", glowColor);
    AcceptEntityInput(outlineEntity, "StartGlowing");

    // 设置轮廓实体渲染模式与可见性（默认隐藏模型，仅显示发光外轮廓）
    SetEntityRenderMode(outlineEntity, RENDER_TRANSCOLOR);
    if (HasEntProp(outlineEntity, Prop_Send, "m_clrRender"))
        SetEntityRenderColor(outlineEntity, 0, 0, 0, 0);
    
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
void ClearDoorOutlines()
{
    for (int i = 0; i < g_aBlinkingDoors.Length; i++)
    {
        int door = g_aBlinkingDoors.Get(i);
        if (IsValidEntity(door) && g_iOutlineIndex[door] != 0)
            RemoveEntityOutline(door);
    }
}

// 检查实体引用是否有效
bool IsValidEntRef(int entity)
{
    if (entity && EntRefToEntIndex(entity) != INVALID_ENT_REFERENCE)
        return true;
    return false;
}

// 轮廓传输钩子 - 只对生还者显示
Action Hook_SetTransmit_Outline(int entity, int client)
{
    if (GetClientTeam(client) != 2) // 不是生还者团队
        return Plugin_Handled;
        
    return Plugin_Continue;
}

int FindNearestEntitybyName(int i, const char[] targetClassname)
{
    float refPos[3];
    if (i >= 1 && i <= MaxClients)
        GetClientAbsOrigin(i, refPos);
    else
        GetEntPropVector(i, Prop_Send, "m_vecOrigin", refPos);

    int nearestEntity = -1;
    float minDistance = -1.0;

    int entity = -1;
    while ((entity = FindEntityByClassname(entity, targetClassname)) != -1)
    {
        if (entity == i) continue;
        
        float targetPos[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", targetPos);
        
        float distance = GetVectorDistance(refPos, targetPos);

        if (distance > MAX_SEARCH_DIST) continue;
        
        if (minDistance < 0 || distance < minDistance)
        {
            minDistance = distance;
            nearestEntity = entity;
        }
    }
    
    return nearestEntity;
}

// 直接设置门实体的关联计数；若门不在列表中则添加
void SetDoorCount(int doorEntity, int count)
{
    if (doorEntity == -1)
        return;

    // 确保门在闪烁列表中
    int doorIndex = g_aBlinkingDoors.FindValue(doorEntity);
    if (doorIndex == -1)
        g_aBlinkingDoors.Push(doorEntity);

    // 在计数数组中查找并设置对应计数
    int countIndex = -1;
    for (int i = 0; i < g_aDoorEntityCounts.Length; i += 2)
    {
        if (g_aDoorEntityCounts.Get(i) == doorEntity)
        {
            countIndex = i;
            break;
        }
    }

    if (countIndex != -1)
        g_aDoorEntityCounts.Set(countIndex + 1, count);
    else
    {
        g_aDoorEntityCounts.Push(doorEntity);
        g_aDoorEntityCounts.Push(count);
    }
}

// 获取门实体的关联次数
int GetDoorCount(int doorEntity)
{
    for (int i = 0; i < g_aDoorEntityCounts.Length; i += 2)
    {
        if (g_aDoorEntityCounts.Get(i) == doorEntity)
            return g_aDoorEntityCounts.Get(i + 1);
    }
    return 0; // 未找到返回0
}

void ClearRescuePoints()
{
    for (int i = 0; i < g_aBlinkingRescue.Length; i++)
    {
        int point = g_aBlinkingRescue.Get(i);
        RemoveEntityOutline(point);
    }
    g_aBlinkingRescue.Clear();
}

void EndDoorBlink(int door)

{
    if (!IsValidEntity(door))
        return;

    if (!HasEntProp(door, Prop_Send, "m_isRescueDoor"))
        return;

    if (HasEntProp(door, Prop_Send, "m_clrRender"))
        SetEntityRenderColor(door, 255, 255, 255, 255);
}

void ClearAll()
{
    if (g_hTimer != null)
    {
        if (IsValidHandle(g_hTimer))
            delete g_hTimer;
        g_hTimer = null;
    }
    for (int i = 0; i < g_aBlinkingDoors.Length; i++)
        EndDoorBlink(g_aBlinkingDoors.Get(i));

    ClearDoorOutlines();
    g_aBlinkingDoors.Clear();
    ClearRescuePoints();
    g_aDoorEntityCounts.Clear();
    g_aRescueEntities.Clear();
    g_aRescueGroups.Clear();
    g_aGroupHasDoor.Clear();
    
    for(int i=0; i<2048; i++) g_iDoorGroup[i] = -1;
}

bool CheckPosition(float pos[3], int navMask)
{
    Address area = L4D_GetNearestNavArea(pos, 300.0, true, false, false, 0); // 位置；搜索距离；忽略高度差距；检查视线；检查地面连接；类型

    if (area == Address_Null)
        return false;

    int attributes = L4D_GetNavArea_SpawnAttributes(area);

    return (attributes & navMask) != 0;
}

// 第一次遍历：收集所有 info_survivor_rescue 实体及其所在的 NavArea ID。
// 第二次遍历（分组与 BFS）：
// 对未分组的实体发起 BFS 搜索。
// 搜索仅在 NAV_MESH_RESCUE_CLOSET 区域间进行，且要求双向连通（排除假复活点）。
// 如果遇到其他救援点实体所在的区域，将其加入当前组。
// 如果遇到 NAV_SPAWN_DESTROYED_DOOR 区域，标记 bHasDoor = true，并将其视为“隔断”（crossedDoor 标记），阻止跨越门的实体加入当前组，但允许 BFS 继续搜索以寻找出口
// 如果遇到非 NAV_MESH_RESCUE_CLOSET 区域，标记 bHasExit = true（找到了出口）（排除假复活点）。
// 后处理：
// 如果一组救援点没有找到出口（!bHasExit），则将该组内的所有实体废弃（排除假复活点）。

void ProcessRescuePoints()
{
    ArrayList s0_Entities = new ArrayList();
    ArrayList s0_AreaIDs = new ArrayList();
    ArrayList s0_GroupIDs = new ArrayList(); // -1: 未分配
    ArrayList s0_GroupHasDoor = new ArrayList();
    
    // 1. 第一遍：收集所有 info_survivor_rescue
    int s0_ent = -1;
    while ((s0_ent = FindEntityByClassname(s0_ent, "info_survivor_rescue")) != -1)
    {
        float pos[3];
        GetEntPropVector(s0_ent, Prop_Data, "m_vecOrigin", pos);
        Address area = L4D_GetNearestNavArea(pos, 300.0, true, false, false, 0);
        if (area != Address_Null)
        {
            s0_Entities.Push(s0_ent);
            s0_AreaIDs.Push(L4D_GetNavAreaID(area));
            s0_GroupIDs.Push(-1);
        }
    }

    ArrayList s0_AllAreas = new ArrayList();
    L4D_GetAllNavAreas(s0_AllAreas);
    int s0_TotalAreas = s0_AllAreas.Length;

    int s0_CurrentGroupID = 0;
    
    for (int i = 0; i < s0_Entities.Length; i++)
    {
        if (s0_GroupIDs.Get(i) != -1) continue;

        int thisGroupID = s0_CurrentGroupID++;
        s0_GroupIDs.Set(i, thisGroupID);
        
        bool bHasDoor = false;
        bool bHasExit = false;

        // BFS 初始化
        // 队列存储数组: [Address(as int/any), crossedDoor(0/1)]
        ArrayList queue = new ArrayList(2); 
        ArrayList visited = new ArrayList();
        
        int startEnt = s0_Entities.Get(i);
        float startPos[3];
        GetEntPropVector(startEnt, Prop_Data, "m_vecOrigin", startPos);
        Address startArea = L4D_GetNearestNavArea(startPos, 300.0, true, false, false, 0);
        
        if (startArea != Address_Null)
        {
            int startAttrs = L4D_GetNavArea_SpawnAttributes(startArea);
            bool startIsDoor = (startAttrs & NAV_SPAWN_DESTROYED_DOOR) != 0;
            if (startIsDoor) bHasDoor = true;

            any startData[2];
            startData[0] = startArea;
            startData[1] = 0; 
            
            queue.PushArray(startData);
            visited.Push(L4D_GetNavAreaID(startArea));
        }

        while (queue.Length > 0)
        {
            any curData[2];
            queue.GetArray(0, curData);
            queue.Erase(0);
            
            Address curArea = curData[0];
            bool curCrossed = curData[1] == 1;
            
            int curAreaID = L4D_GetNavAreaID(curArea);
            int curAttrs = L4D_GetNavArea_SpawnAttributes(curArea);
            bool curIsDoor = (curAttrs & NAV_SPAWN_DESTROYED_DOOR) != 0;

            // 分组：检查此区域是否有其他实体
            if (!curCrossed)
            {
                for (int j = 0; j < s0_Entities.Length; j++)
                {
                    // 跳过自己或已在当前组的实体
                    if (s0_GroupIDs.Get(j) == thisGroupID) continue;

                    if (s0_AreaIDs.Get(j) == curAreaID)
                    {
                        int otherGroupID = s0_GroupIDs.Get(j);
                        if (otherGroupID == -1)
                        {
                            // 未分组实体，直接加入
                            s0_GroupIDs.Set(j, thisGroupID);
                        }
                        else 
                        {
                            // 发现已分组的实体（可能是之前的组，或者是被废弃的组），将其合并到当前组
                            // 这种情况通常发生在：当前搜索路径连通到了一个已存在的组
                            // 我们将那个组的所有成员“拉”入当前组
                            for (int k = 0; k < s0_Entities.Length; k++)
                            {
                                if (s0_GroupIDs.Get(k) == otherGroupID)
                                {
                                    s0_GroupIDs.Set(k, thisGroupID);
                                }
                            }
                        }
                    }
                }
            }

            // 查找邻居
            for (int k = 0; k < s0_TotalAreas; k++)
            {
                Address neighbor = s0_AllAreas.Get(k);
                if (neighbor == curArea) continue;

                int neighborID = L4D_GetNavAreaID(neighbor);
                
                // 检查连接（双向）
                if (!L4D_NavArea_IsConnected(curArea, neighbor, 4) || !L4D_NavArea_IsConnected(neighbor, curArea, 4))
                    continue;

                int attrs = L4D_GetNavArea_SpawnAttributes(neighbor);
                
                // 检查出口（非 RescueCloset）
                if ((attrs & NAV_MESH_RESCUE_CLOSET) == 0)
                {
                    bHasExit = true;
                    // 不遍历非 closet 区域
                    continue;
                }

                // 检查门
                bool neighborIsDoor = (attrs & NAV_SPAWN_DESTROYED_DOOR) != 0;
                if (neighborIsDoor) bHasDoor = true;

                // 正常的 RescueCloset 邻居（包括门）
                if (visited.FindValue(neighborID) == -1)
                {
                    // 隔断逻辑：
                    // 只有当"当前区域"已经是门(curIsDoor)或者是门后区域(curCrossed)时，
                    // 进入下一个区域才算作"穿过门"(nextCrossed)。
                    // 也就是说，如果 neighbor 是门，进入 neighbor 时 nextCrossed 还是 false（允许把门内的实体加组），
                    // 但从 neighbor 再往外走时，因为 neighbor 是门，所以那时的 nextCrossed 就会变成 true。
                    bool nextCrossed = curCrossed || curIsDoor;
                    
                    any nextData[2];
                    nextData[0] = neighbor;
                    nextData[1] = nextCrossed ? 1 : 0;
                    
                    visited.Push(neighborID);
                    queue.PushArray(nextData);
                }
            }
        }
        
        delete queue;
        delete visited;

        s0_GroupHasDoor.Push(bHasDoor ? 1 : 0);

        // 分组后处理
        // 如果未找到出口，丢弃该组（排除假复活点）
        if (!bHasExit)
        {
            // 标记该组中的所有实体为废弃（不加入最终列表）
            for (int j = 0; j < s0_Entities.Length; j++)
            {
                if (s0_GroupIDs.Get(j) == thisGroupID)
                {
                    s0_GroupIDs.Set(j, -2); // -2 表示废弃
                }
            }
        }
    }

    // 用有效实体和组填充全局变量
    for (int i = 0; i < s0_Entities.Length; i++)
    {
        int ent = s0_Entities.Get(i);
        int groupID = s0_GroupIDs.Get(i);
        //int areaID = s0_AreaIDs.Get(i);
        
        //PrintToChatAll("RescueEntity: %d, Area: %d, Group: %d", ent, areaID, groupID);
        //PrintToServer("RescueEntity: %d, Area: %d, Group: %d", ent, areaID, groupID);
        
        if (IsValidEntity(ent) && groupID >= 0)
        {
            g_aRescueEntities.Push(ent);
            g_aRescueGroups.Push(groupID);
        }
    }
    
    // 复制组门状态
    for (int i = 0; i < s0_GroupHasDoor.Length; i++)
    {
        g_aGroupHasDoor.Push(s0_GroupHasDoor.Get(i));
    }

    delete s0_Entities;
    delete s0_AreaIDs;
    delete s0_GroupIDs;
    delete s0_GroupHasDoor;
    delete s0_AllAreas;
}

// 筛选与搜索：遍历所有属于 HasDoor 标记组的 info_survivor_rescue 实体，搜索其 600 码范围内的救援门。
// 排序：将所有搜索结果（距离、门ID、救援点ID、组ID）按距离升序排列。
// 分配与计数：
// 首次被组认领：如果门未被任何组认领，则记录该组ID，计数设为1，并标记该救援点已贡献计数。
// 同组再次认领：如果门已被同组认领，计数+1，并标记该救援点已贡献计数。
// 异组认领：如果门已被其他组认领，则忽略。
// 后续处理：
// 对未贡献计数的救援点创建外轮廓并添加到 g_BlinkingRescue 列表中
// 对有计数的门调用 SetDoorCount 设置最终计数。
void AssignRescueDoorsToGroups()
{
    // int doorOwnerGroup[2048]; // 使用全局 g_iDoorGroup
    int doorCount[2048];
    bool entityHasDoor[2048];
    
    for (int i = 0; i < 2048; i++) {
        // doorOwnerGroup[i] = -1; // 已在 ClearAll 中重置
        doorCount[i] = 0;
        entityHasDoor[i] = false;
    }

    ArrayList candidates = new ArrayList(4); // [distance, door, entity, group]

    // 预先收集所有救援门以提高效率
    ArrayList allRescueDoors = new ArrayList();
    int maxEnts = GetMaxEntities();
    for (int i = MaxClients + 1; i < maxEnts; i++)
    {
        if (IsValidEntity(i) && IsRescueDoor(i))
        {
            allRescueDoors.Push(i);
        }
    }

    // 1. 收集候选数据
    for (int i = 0; i < g_aRescueEntities.Length; i++)
    {
        int ent = g_aRescueEntities.Get(i);
        int groupId = g_aRescueGroups.Get(i);
        
        // 只处理 HasDoor 为 true 的组
        if (groupId >= 0 && groupId < g_aGroupHasDoor.Length)
        {
            if (g_aGroupHasDoor.Get(groupId) == 0) continue;
        }
        else continue;

        if (!IsValidEntity(ent)) continue;

        float entPos[3];
        GetEntPropVector(ent, Prop_Data, "m_vecOrigin", entPos);

        for (int d = 0; d < allRescueDoors.Length; d++)
        {
            int door = allRescueDoors.Get(d);
            
            float doorPos[3];
            GetEntPropVector(door, Prop_Send, "m_vecOrigin", doorPos);
            float dist = GetVectorDistance(entPos, doorPos);
            
            if (dist <= 600.0)
            {
                any data[4];
                data[0] = dist;
                data[1] = door;
                data[2] = ent;
                data[3] = groupId;
                candidates.PushArray(data);
            }
        }
    }
    delete allRescueDoors;

    // 2. 按距离升序排序
    candidates.Sort(Sort_Ascending, Sort_Float);

    // 3. 处理候选数据
    for (int i = 0; i < candidates.Length; i++)
    {
        any data[4];
        candidates.GetArray(i, data);
        int door = data[1];
        int ent = data[2];
        int group = data[3];
        
        if (g_iDoorGroup[door] == -1)
        {
            // 第一次被新组添加
            g_iDoorGroup[door] = group;
            doorCount[door] = 1;
            entityHasDoor[ent] = true;
        }
        else if (g_iDoorGroup[door] == group)
        {
            // 被同组添加
            doorCount[door]++;
            entityHasDoor[ent] = true;
        }
        // 被其他组添加则不做处理
    }
    delete candidates;

    // 4. 处理没有分配门的救援点实体
    for (int i = 0; i < g_aRescueEntities.Length; i++)
    {
        int ent = g_aRescueEntities.Get(i);
        int groupId = g_aRescueGroups.Get(i);
        
        if (groupId >= 0 && groupId < g_aGroupHasDoor.Length)
        {
            if (IsValidEntity(ent) && !entityHasDoor[ent])
            {
                CreateEntityOutline(ent, g_iRescueColor[0], g_iRescueColor[1], g_iRescueColor[2]); // 使用配置的救援点轮廓颜色
                g_aBlinkingRescue.Push(ent);
            }
        }
    }

    // 5. 设置门计数
    for (int i = 0; i < 2048; i++)
    {
        if (doorCount[i] > 0)
        {
            SetDoorCount(i, doorCount[i]);
        }
    }
}

public void Event_RoundStartPostNav(Event event, const char[] name, bool dontBroadcast)
{
    CreateTimer(3.0, Timer_RoundStart, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_RoundStart(Handle timer)
{
    g_iCurrentCount = 0;
    g_iTotalRescuePoints = 0;  // 重置救援点计数

    ClearAll();

    // 给所有救援实体分组，并剔除假复活点
    ProcessRescuePoints();

    // 记录总救援点数量
    g_iTotalRescuePoints = g_aRescueEntities.Length;

    // 对救援门进行分配组和计数，对于没有分配到门的救援实体，创建外轮廓提示
    AssignRescueDoorsToGroups();

    // 使用配置的闪烁速度
    float blinkSpeed = GetConVarFloat(g_hBlinkSpeed);
    g_hTimer = CreateTimer(blinkSpeed, Timer_DoorBlink, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Continue;
}

public Action Timer_DoorBlink(Handle timer)
{
    if (g_aBlinkColors.Length == 0)
        return Plugin_Continue;
    
    int colorCount = g_aBlinkColors.Length / 3; // 每个颜色3个值(RGB)
    
    for (int i = 0; i < g_aBlinkingDoors.Length; i++)
    {
        int door = g_aBlinkingDoors.Get(i);
        if (!IsValidEntity(door))
        {
            g_aBlinkingDoors.Erase(i);
            i--;
        }
        else
        {
            // 获取门的计数，决定闪烁模式
            int doorCount = GetDoorCount(door);
            if (doorCount <= 0) continue; // 如果计数为0或无效，跳过
            
            // 限制计数在1-3之间
            doorCount = (doorCount > 3) ? 3 : doorCount;
            
            // 根据门计数确定一轮闪烁的总步数（计数颜色+白色）
            int totalSteps = doorCount + 1;
            int currentStep = g_iCurrentCount % totalSteps;
            
            int r, g, b;
            
            if (currentStep < doorCount)
            {
                // 显示对应计数的颜色之一
                int colorIndex = currentStep % colorCount; // 循环使用可用颜色
                int arrayIndex = colorIndex * 3;
                
                if (arrayIndex + 2 < g_aBlinkColors.Length)
                {
                    r = g_aBlinkColors.Get(arrayIndex);
                    g = g_aBlinkColors.Get(arrayIndex + 1);
                    b = g_aBlinkColors.Get(arrayIndex + 2);
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
    
    if (g_iCurrentCount > 30000)
        g_iCurrentCount = 0;
    
    g_iCurrentCount++;
    
    return Plugin_Continue;
}

public Action Timer_RescueNotification(Handle timer)
{
    PrintToChatAll("\x01救援事件触发 本章节剩余复活门\x03%d\x01扇 \x01剩余标记的救援点实体\x03%d\x01个", g_aBlinkingDoors.Length, g_aBlinkingRescue.Length);
    return Plugin_Continue;
}

public void Event_PlayerLeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    PrintToChatAll("\x01本章节共有复活门\x03%d\x01扇 \x01救援点实体\x03%d\x01个 \x01其中标记的救援点实体\x03%d\x01个", g_aBlinkingDoors.Length, g_iTotalRescuePoints, g_aBlinkingRescue.Length);
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    
    if (client <= 0 || client > MaxClients)
        return Plugin_Continue;
    
    if (!IsClientConnected(client) || !IsClientInGame(client))
        return Plugin_Continue;
    
    if (GetClientTeam(client) != 2)
        return Plugin_Continue;
    
    ConVar rescuetimeCvar = FindConVar("rescue_min_dead_time");
    int rescueTime = (rescuetimeCvar != null) ? rescuetimeCvar.IntValue : 60;

    float currentTime = GetGameTime();
    if (FloatAbs(currentTime - g_fLastNotifyTime) >= 5.0)
    {
        PrintToChatAll("\x01本章节剩余复活门\x03%d\x01扇 \x01剩余标记的救援点实体\x03%d\x01个 \x01救援等待时间\x03%d\x01秒", 
            g_aBlinkingDoors.Length, g_aBlinkingRescue.Length, rescueTime);
        
        g_fLastNotifyTime = currentTime;
    }

    if (g_hRescueStartTimer[client] != null && IsValidHandle(g_hRescueStartTimer[client]))
    {
        delete g_hRescueStartTimer[client];
        g_hRescueStartTimer[client] = null;
    }
    g_hRescueStartTimer[client] = CreateTimer(float(rescueTime), Timer_StartRescueBlockCheck, client, TIMER_FLAG_NO_MAPCHANGE);
    
    return Plugin_Continue;
}

//等待rescueTime时间后启动救援阻塞检测
public Action Timer_StartRescueBlockCheck(Handle timer, any data)
{
    int client = data;

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        if (g_hRescueStartTimer[client] == timer)
            g_hRescueStartTimer[client] = null;
        return Plugin_Stop;
    }

    if (IsPlayerAlive(client))
    {
        if (g_hRescueStartTimer[client] == timer)
            g_hRescueStartTimer[client] = null;
        return Plugin_Stop;
    }

    if (g_hRescueStartTimer[client] == timer)
        g_hRescueStartTimer[client] = null;

    if (g_hRescueRepeatTimer[client] != null && IsValidHandle(g_hRescueRepeatTimer[client]))
    {
        delete g_hRescueRepeatTimer[client];
        g_hRescueRepeatTimer[client] = null;
    }

    g_hRescueRepeatTimer[client] = CreateTimer(1.0, Timer_RescueBlockCheck, client, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Stop;
}

// 1) 若玩家已非死亡状态或已经是待救援状态，则停止检测；
// 2) 检查所有生还者队伍中存活玩家1200范围内是否存在标记救援点且处于 rescue_closet 区域；
//    若有，向这些玩家发送提示信息
public Action Timer_RescueBlockCheck(Handle timer, any data)
{
    int client = data;

    if (client <= 0 || client > MaxClients || !IsClientInGame(client))
    {
        if (g_hRescueRepeatTimer[client] == timer)
            g_hRescueRepeatTimer[client] = null;
        return Plugin_Stop;
    }

    if (IsPlayerAlive(client))
    {
        if (g_hRescueRepeatTimer[client] == timer)
            g_hRescueRepeatTimer[client] = null;
        return Plugin_Stop;
    }

    if (g_aBlinkingRescue.Length == 0)
    {
        if (g_hRescueRepeatTimer[client] == timer)
            g_hRescueRepeatTimer[client] = null;
        return Plugin_Stop; // 无标记救援点
    }

    // 若有救援实体的 m_survivor 指向该死亡玩家则停止检测 若指向了其他玩家则跳过后续检测
    for (int rpIndex = 0; rpIndex < g_aBlinkingRescue.Length; rpIndex++)
    {
        int rescueEnt = g_aBlinkingRescue.Get(rpIndex);
        if (!IsValidEntity(rescueEnt))
            continue;

        int linked = -1;
        linked = GetEntPropEnt(rescueEnt, Prop_Send, "m_survivor");

        if (linked == client)
        {
            if (g_hRescueRepeatTimer[client] == timer)
                g_hRescueRepeatTimer[client] = null;
            return Plugin_Stop;
        }
        else if (linked >=1 && linked <= MaxClients)
            return Plugin_Continue;
    }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2 || !IsPlayerAlive(i))
            continue;

        float pos[3];
        GetClientAbsOrigin(i, pos);

        bool nearAnyRescue = false;
        for (int rp = 0; rp < g_aBlinkingRescue.Length; rp++)
        {
            int rescueEnt = g_aBlinkingRescue.Get(rp);
            if (!IsValidEntity(rescueEnt))
                continue;

            float rpPos[3];
            GetEntPropVector(rescueEnt, Prop_Data, "m_vecOrigin", rpPos);
            if (GetVectorDistance(pos, rpPos) <= 1200.0)
            {
                nearAnyRescue = true;
                break;
            }
        }
        if (!nearAnyRescue)
            continue;

        Address area = L4D_GetNearestNavArea(pos, 300.0, true, false, false, 0);
        if (area == Address_Null)
            continue;

        int attrs = L4D_GetNavArea_SpawnAttributes(area);
        if ((attrs & NAV_MESH_RESCUE_CLOSET) != 0)
        {
            PrintHintText(i, "你所处区域因导航标记错误导致死亡的玩家无法复活 请移动到其他区域(远离被标记的救援点)");
        }
    }

    return Plugin_Continue;
}

public void Event_RescueDoorOpen(Event event, const char[] name, bool dontBroadcast)
{

    int doorEntity = event.GetInt("entindex");
    int find_entity = FindNearestEntitybyName(doorEntity, "info_survivor_rescue");

    if (find_entity == -1) return;

    float pos[3];
    GetEntPropVector(find_entity, Prop_Data, "m_vecOrigin", pos);

    if(!CheckPosition(pos, NAV_MESH_FINALE))
    {
        // 寻找被开启的门所属的组
        int targetGroup = g_iDoorGroup[doorEntity];

        if (targetGroup != -1)
        {
            // 移除所有属于该组的门
            for (int j = g_aBlinkingDoors.Length - 1; j >= 0; j--)
            {
                int bDoor = g_aBlinkingDoors.Get(j);
                if (!IsValidEntity(bDoor)) 
                {
                    g_aBlinkingDoors.Erase(j);
                    continue;
                }
                
                if (g_iDoorGroup[bDoor] == targetGroup)
                {
                    EndDoorBlink(bDoor);
                    RemoveEntityOutline(bDoor);
                    g_aBlinkingDoors.Erase(j);
                }
            }
        }
        else
        {
            int i = g_aBlinkingDoors.FindValue(doorEntity);
            if (i != -1)
            {
                EndDoorBlink(doorEntity);
                RemoveEntityOutline(doorEntity);
                g_aBlinkingDoors.Erase(i);
            }
        }

        float currentTime = GetGameTime();
        PrintToChatAll("\x01复活门已被开启 \x01本章节剩余复活门\x03%d\x01扇 \x01剩余标记的救援点实体\x03%d\x01个", g_aBlinkingDoors.Length, g_aBlinkingRescue.Length);
        g_fLastNotifyTime = currentTime;
    }
}

public Action Event_SurvivorRescued(Event event, const char[] name, bool dontBroadcast)
{
    // 1. 获取victim的用户ID（UserID）
    int victimUserID = event.GetInt("victim");
    // 2. 将UserID转换为客户端索引
    int victimClient = GetClientOfUserId(victimUserID);
    int find_entity_rescue = FindNearestEntitybyName(victimClient, "info_survivor_rescue");

    RemoveEntityOutline(find_entity_rescue);
    int rpIndex = g_aBlinkingRescue.FindValue(find_entity_rescue);
    if (rpIndex != -1)
        g_aBlinkingRescue.Erase(rpIndex);

    float currentTime = GetGameTime();
    if (FloatAbs(currentTime - g_fLastNotifyTime) >= 5.0)
    {
        // 延迟3秒执行通知
        CreateTimer(3.0, Timer_RescueNotification, _, TIMER_FLAG_NO_MAPCHANGE);
        g_fLastNotifyTime = currentTime;
    }

    return Plugin_Continue;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_hRescueStartTimer[i] != null && IsValidHandle(g_hRescueStartTimer[i]))
            delete g_hRescueStartTimer[i];
        g_hRescueStartTimer[i] = null;

        if (g_hRescueRepeatTimer[i] != null && IsValidHandle(g_hRescueRepeatTimer[i]))
            delete g_hRescueRepeatTimer[i];
        g_hRescueRepeatTimer[i] = null;
    }

    ClearAll();
}

public void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (g_hRescueStartTimer[i] != null && IsValidHandle(g_hRescueStartTimer[i]))
            delete g_hRescueStartTimer[i];
        g_hRescueStartTimer[i] = null;

        if (g_hRescueRepeatTimer[i] != null && IsValidHandle(g_hRescueRepeatTimer[i]))
            delete g_hRescueRepeatTimer[i];
        g_hRescueRepeatTimer[i] = null;
    }

    ClearAll();
    
    PrintToChatAll("\x01章节救援开始！所有复活门及救援实体已\x03失效");
}