#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#pragma newdecls required
#define PLUGIN_VERSION "1.3.0"

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

    ！！！以上信息无游戏源码支撑，仅是本人通过观察实际游戏行为和导航网格属性推测并验证得出，仅供参考。如果各位有更准确的信息或新的结论，欢迎交流

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
    g_aBlinkingDoors,
    g_aBlinkColors,    // 存储颜色数组
    g_aRescuePoints,   // 存储救援点实体
    g_aDoorEntityCounts; // 存储门实体和对应的关联次数（成对存储：实体ID，计数）
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
    g_aBlinkColors = new ArrayList(3); // 存储RGB值，每个颜色3个值
    g_aRescuePoints = new ArrayList(); // 存储救援点实体标记
    g_aDoorEntityCounts = new ArrayList(2); // 存储门实体和计数（每个条目2个值：实体ID，计数）

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

// 以起点为开始，仅在含 NAV_MESH_RESCUE_CLOSET 的区域集合内进行 BFS；
// 一旦遇到含 NAV_SPAWN_DESTROYED_DOOR 的区域，则返回 true；否则遍历完返回 false
bool IsPathConnectedDoor(float vStartPos[3])
{
    // 起点所在的最近导航区域
    Address startArea = L4D_GetNearestNavArea(vStartPos, 300.0, true, false, false, 0);
    if (startArea == Address_Null)
        return false;

    // 获取全部导航区域并仅保留含 NAV_MESH_RESCUE_CLOSET 的区域
    ArrayList areas = new ArrayList();
    L4D_GetAllNavAreas(areas);

    ArrayList closetAreas = new ArrayList();
    int total = areas.Length;
    for (int i = 0; i < total; i++)
    {
        Address a = areas.Get(i);
        int attrs = L4D_GetNavArea_SpawnAttributes(a);
        if ((attrs & NAV_MESH_RESCUE_CLOSET) != 0)
            closetAreas.Push(a);
    }

    int closetTotal = closetAreas.Length;
    if (closetTotal == 0)
    {
        delete areas;
        delete closetAreas;
        return false;
    }

    // 访问标记（按 NavArea ID）与 BFS 队列（Address）
    ArrayList visited = new ArrayList();
    ArrayList queue   = new ArrayList();

    // 起点是 closet 区域，否则直接返回 false
    int startAttrs = L4D_GetNavArea_SpawnAttributes(startArea);
    if ((startAttrs & NAV_MESH_RESCUE_CLOSET) == 0)
    {
        delete areas;
        delete closetAreas;
        delete visited;
        delete queue;
        return false;
    }

    // 起点本身就带有 Destroyed Door，直接返回 true
    if ((startAttrs & NAV_SPAWN_DESTROYED_DOOR) != 0)
    {
        delete areas;
        delete closetAreas;
        delete visited;
        delete queue;
        return true;
    }

    // 起点入队
    queue.Push(startArea);
    visited.Push(L4D_GetNavAreaID(startArea));

    while (queue.Length > 0)
    {
        Address cur = queue.Get(0);
        queue.Erase(0);

        for (int i = 0; i < closetTotal; i++)
        {
            Address cand = closetAreas.Get(i);
            if (cand == cur)
                continue;

            int candId = L4D_GetNavAreaID(cand);
            if (visited.FindValue(candId) != -1)
                continue;

            if (!L4D_NavArea_IsConnected(cur, cand, 4))
                continue;

            int attrs = L4D_GetNavArea_SpawnAttributes(cand);
            if ((attrs & NAV_SPAWN_DESTROYED_DOOR) != 0)
            {
                delete areas;
                delete closetAreas;
                delete visited;
                delete queue;
                return true;
            }

            visited.Push(candId);
            queue.Push(cand);
        }
    }

    delete areas;
    delete closetAreas;
    delete visited;
    delete queue;

    return false;
}

// 从 rescues 中选择并标记距离 doorPos 最近的最多 maxPick 个救援点（在 MAX_SEARCH_DIST 内），返回成功标记的数量
int MarkNearestRescueWithinRange(float doorPos[3], float searchRadius, ArrayList rescues, ArrayList markLeft, int maxPick)
{
    if (maxPick < 1)
        return 0;

    if (maxPick > 3)
        maxPick = 3; // 最多只统计3个

    int count = 0;

    int topIdx[3];
    float topDist[3];
    for (int k = 0; k < 3; k++)
    {
        topIdx[k] = -1;
        topDist[k] = -1.0;
    }

    for (int i = 0; i < rescues.Length; i++)
    {
        if (markLeft.Get(i) == 0)
            continue;

        int rp = rescues.Get(i);

        float rpPos[3];
        GetEntPropVector(rp, Prop_Data, "m_vecOrigin", rpPos);
        float dist = GetVectorDistance(doorPos, rpPos);
        if (dist > searchRadius)
            continue;

        //与门的连通性检查(仅当 maxPick != 1 即非单间厕所门时启用)
        if (maxPick != 1 && !IsPathConnectedDoor(rpPos))
            continue;

        // 插入有序队列（按距离升序，容量 maxPick）
        int slot = -1;
        for (int p = 0; p < maxPick; p++)
        {
            if (topDist[p] < 0.0 || dist < topDist[p])
            {
                slot = p;
                break;
            }
        }

        if (slot != -1)
        {
            for (int k = maxPick - 1; k > slot; k--)
            {
                topDist[k] = topDist[k - 1];
                topIdx[k] = topIdx[k - 1];
            }
            topDist[slot] = dist;
            topIdx[slot] = i;
        }
    }

    // 标记最近的 maxPick 个救援点
    for (int p = 0; p < maxPick; p++)
    {
        if (topIdx[p] != -1)
        {
            markLeft.Set(topIdx[p], 0);
            count++;
        }
    }

    return count;
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

void AddRescuePointEntity(int rescueEntity)
{
    if (rescueEntity == -1) return;
    
    // 检查救援点是否已经在列表中
    int index = g_aRescuePoints.FindValue(rescueEntity);
    if (index == -1)
        g_aRescuePoints.Push(rescueEntity);
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
    for (int i = 0; i < g_aRescuePoints.Length; i++)
    {
        int point = g_aRescuePoints.Get(i);
        RemoveEntityOutline(point);
    }
    g_aRescuePoints.Clear();
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
    g_aDoorEntityCounts.Clear();
    ClearRescuePoints();
}

bool CheckPosition(float pos[3], int navMask)
{
    Address area = L4D_GetNearestNavArea(pos, 300.0, true, false, false, 0); // 位置；搜索距离；忽略高度差距；检查视线；检查地面连接；类型

    if (area == Address_Null)
        return false;

    int attributes = L4D_GetNavArea_SpawnAttributes(area);

    return (attributes & navMask) != 0;
}

// 检查：从某个救援点实体所在的起始导航区域出发，
// 使用 BFS 遍历与其连通的所有其他区域；
// 一旦遇到“未包含 NAV_MESH_RESCUE_CLOSET 属性”的区域，立即返回 true；
// 若遍历完所有连通区域仍未找到，则返回 false。
bool IsTrueRescue(int rescueEntity)
{
    if (!IsValidEntity(rescueEntity))
        return false;

    float vStartPos[3];
    GetEntPropVector(rescueEntity, Prop_Data, "m_vecOrigin", vStartPos);

    Address startArea = L4D_GetNearestNavArea(vStartPos, 300.0, true, false, false, 0);
    if (startArea == Address_Null)
        return false;

    // 获取地图全部导航区域供连通性判定使用
    ArrayList areas = new ArrayList();
    L4D_GetAllNavAreas(areas);

    // 访问标记（按 NavArea ID），以及 BFS 队列（Address）
    ArrayList visited = new ArrayList();
    ArrayList queue   = new ArrayList();

    // 起点入队并标记已访问
    queue.Push(startArea);
    visited.Push(L4D_GetNavAreaID(startArea));

    bool found = false;

    while (queue.Length > 0)
    {
        Address cur = queue.Get(0);
        queue.Erase(0);

        // 遍历所有区域，找出与当前区域“直接连通”的候选
        int total = areas.Length;
        for (int i = 0; i < total; i++)
        {
            Address cand = areas.Get(i);
            if (cand == cur)
                continue;

            int candId = L4D_GetNavAreaID(cand);
            if (visited.FindValue(candId) != -1)
                continue;

            // 仅考虑与 cur 双向直接连通的区域（四个方向 NAV_ALL=4）
            if (!L4D_NavArea_IsConnected(cur, cand, 4) || !L4D_NavArea_IsConnected(cand, cur, 4))
                continue;

            // 一旦遇到“不包含 NAV_MESH_RESCUE_CLOSET 属性”的区域，立即返回 true
            int attrs = L4D_GetNavArea_SpawnAttributes(cand);
            if ((attrs & NAV_MESH_RESCUE_CLOSET) == 0)
            {
                found = true;
                break;
            }

            // 否则继续向外扩展 BFS
            visited.Push(candId);
            queue.Push(cand);
        }

        if (found)
            break;
    }

    delete areas;
    delete visited;
    delete queue;

    return found;
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

    // Step 1: 遍历所有 info_survivor_rescue，记录并标记为“待处理(1)”, 并且排除“假”救援点
    ArrayList rescues = new ArrayList();      // 存实体ID
    ArrayList markLeft = new ArrayList();     // 1=未被任何门统计, 0=已被某门统计
    int ent = -1;
    while ((ent = FindEntityByClassname(ent, "info_survivor_rescue")) != -1)
    {
        if (!IsTrueRescue(ent))
            continue;
        rescues.Push(ent);
        markLeft.Push(1);
    }
    g_iTotalRescuePoints = rescues.Length;

    // Step 2: 遍历所有实体，筛选标准救援门范围内救援点
    int maxEnts = GetMaxEntities();
    for (int door = MaxClients + 1; door < maxEnts; door++)
    {
        if (!IsValidEntity(door))
            continue;

        if (!IsRescueDoor(door))
            continue;

        int count = 0;

        float doorPos[3];
        GetEntPropVector(door, Prop_Send, "m_vecOrigin", doorPos);

        // 检查门模型：若为“models/props_urban/outhouse_door001.mdl”(单间厕所门），仅统计最近的一个救援点
        bool bNearestOnly = false;
        char modelName[PLATFORM_MAX_PATH];
        if (GetEntPropString(door, Prop_Data, "m_ModelName", modelName, sizeof(modelName)))
        {
            if (StrEqual(modelName, "models/props_urban/outhouse_door001.mdl", false))
                bNearestOnly = true;
        }

        count = MarkNearestRescueWithinRange(doorPos, float(MAX_SEARCH_DIST), rescues, markLeft, bNearestOnly ? 1 : 3);

        if (count == 0)
            continue;

        SetDoorCount(door, count);
    }

    // Step 3: 添加未被任何门处理的救援点
    for (int i = 0; i < rescues.Length; i++)
    {
        if (markLeft.Get(i) == 1)
        {
            int rp = rescues.Get(i);
            AddRescuePointEntity(rp);
        }
    }

    delete rescues;
    delete markLeft;

    // 使用配置的闪烁速度
    float blinkSpeed = GetConVarFloat(g_hBlinkSpeed);
    g_hTimer = CreateTimer(blinkSpeed, Timer_DoorBlink, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

    for (int i = 0; i < g_aRescuePoints.Length; i++)
        CreateEntityOutline(g_aRescuePoints.Get(i), g_iRescueColor[0], g_iRescueColor[1], g_iRescueColor[2]); // 使用配置的救援点轮廓颜色

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
    PrintToChatAll("\x01救援事件触发 本章节剩余复活门\x03%d\x01扇 \x01剩余标记的救援点实体\x03%d\x01个", g_aBlinkingDoors.Length, g_aRescuePoints.Length);
    return Plugin_Continue;
}

public void Event_PlayerLeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    PrintToChatAll("\x01本章节共有复活门\x03%d\x01扇 \x01救援点实体\x03%d\x01个 \x01其中标记的救援点实体\x03%d\x01个", g_aBlinkingDoors.Length, g_iTotalRescuePoints, g_aRescuePoints.Length);
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
            g_aBlinkingDoors.Length, g_aRescuePoints.Length, rescueTime);
        
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

    if (g_aRescuePoints.Length == 0)
    {
        if (g_hRescueRepeatTimer[client] == timer)
            g_hRescueRepeatTimer[client] = null;
        return Plugin_Stop; // 无标记救援点
    }

    // 若有救援实体的 m_survivor 指向该死亡玩家则停止检测 若指向了其他玩家则跳过后续检测
    for (int rpIndex = 0; rpIndex < g_aRescuePoints.Length; rpIndex++)
    {
        int rescueEnt = g_aRescuePoints.Get(rpIndex);
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
        for (int rp = 0; rp < g_aRescuePoints.Length; rp++)
        {
            int rescueEnt = g_aRescuePoints.Get(rp);
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

    float pos[3];
    GetEntPropVector(find_entity, Prop_Data, "m_vecOrigin", pos);

    if(!CheckPosition(pos, NAV_MESH_FINALE))
    {
        int i = g_aBlinkingDoors.FindValue(doorEntity);
        if (i != -1)
        {
            EndDoorBlink(doorEntity);
            RemoveEntityOutline(doorEntity);
            g_aBlinkingDoors.Erase(i);
        }
        float currentTime = GetGameTime();
        PrintToChatAll("\x01复活门已被开启 \x01本章节剩余复活门\x03%d\x01扇 \x01剩余标记的救援点实体\x03%d\x01个", g_aBlinkingDoors.Length, g_aRescuePoints.Length);
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
    int rpIndex = g_aRescuePoints.FindValue(find_entity_rescue);
    if (rpIndex != -1)
        g_aRescuePoints.Erase(rpIndex);

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