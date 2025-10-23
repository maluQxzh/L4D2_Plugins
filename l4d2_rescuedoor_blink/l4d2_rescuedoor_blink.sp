#include <sourcemod>
#include <sdktools>
#include <left4dhooks>
#include <multicolors>
#pragma newdecls required
#define PLUGIN_VERSION "1.2.0"

#define MAX_SEARCH_DIST 600   // 救援实体为圆心最大搜索距离

#define NAV_MESH_FINALE 64
#define NAV_MESH_RESCUE_CLOSET 65536


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
v1.2.0
    重构大部分代码
    创建点光源效果改为穿透发光的圆形轮廓,不再处理funcdoor类型门,只处理prop_door_rotating和prop_door_rotating_checkpoint类型门
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

int
    g_iCurrentCount,
    g_iTotalRescuePoints;    // 本章节救援点总数
float
    g_fLastNotifyTime;

// 门类型数组
char g_DoorTypes[][64] = {
    "prop_door_rotating",
    "prop_door_rotating_checkpoint"
};

ArrayList
    g_aBlinkingDoors,
    g_aBlinkColors,    // 存储颜色数组
    g_aRescuePoints,   // 存储救援点实体
    g_aDoorEntityCounts; // 存储门实体和对应的关联次数（成对存储：实体ID，计数）
// 轮廓系统变量
int g_iOutlineIndex[2048] = {0};  // 存储每个实体对应的轮廓实体引用
Handle
    g_hTimer = null;
ConVar
    g_hBlinkSpeed,    // 闪烁速度（间隔时间）
    g_hBlinkColors;   // 颜色字符串（RGB值）

public void OnPluginStart()
{
    char game_name[64];
    GetGameFolderName(game_name, sizeof(game_name));
    if (!StrEqual(game_name, "left4dead2", false))
        SetFailState("Plugin supports Left 4 Dead 2 only.");

    CreateConVar("l4d2_rescuedoor_blink_version", PLUGIN_VERSION, "l4d2_rescuedoor_blink version", FCVAR_NOTIFY|FCVAR_REPLICATED|FCVAR_DONTRECORD);

    // 创建配置变量
    g_hBlinkSpeed = CreateConVar("l4d2_rescuedoor_blink_speed", "1.0", "闪烁间隔时间（秒）Blink interval time (seconds)", FCVAR_NOTIFY, true, 0.1, true, 10.0);
    g_hBlinkColors = CreateConVar("l4d2_rescuedoor_blink_colors", "255,0,0;255,255,0;0,255,0", "闪烁颜色列表(R,G,B格式，用分号分隔，共九个值) Blink colors list (R,G,B format, separated by semicolon, 9 values total)", FCVAR_NOTIFY);

    AutoExecConfig(true, "l4d2_rescuedoor_blink");

    g_fLastNotifyTime = GetGameTime();
    g_aBlinkingDoors = new ArrayList();
    g_aBlinkColors = new ArrayList(3); // 存储RGB值，每个颜色3个值
    g_aRescuePoints = new ArrayList(); // 存储救援点实体标记
    g_aDoorEntityCounts = new ArrayList(2); // 存储门实体和计数（每个条目2个值：实体ID，计数）

    // 初始化颜色配置
    UpdateBlinkColors();
    
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

// 预缓存自定义用于轮廓的模型，避免出现 "late precache of models/...atlas_break_ball.mdl" 提示
public void OnMapStart()
{
    PrecacheModel("models/props_unique/airport/atlas_break_ball.mdl", true);
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

// 检查实体是否为符合要求的门类型
bool CheckEntitybyName(int entity)
{
    if (!IsValidEntity(entity))
        return false;
    
    char classname[64];
    GetEntityClassname(entity, classname, sizeof(classname));
    
    for (int i = 0; i < sizeof(g_DoorTypes); i++)
    {
        if (StrEqual(classname, g_DoorTypes[i]))
            return true;
    }
    
    return false;
}

// 判断实体是否是救援门
bool IsRescueDoor(int entity)
{
    return HasEntProp(entity, Prop_Send, "m_isRescueDoor") && GetEntProp(entity, Prop_Send, "m_isRescueDoor") == 1;
}

// 安全地设置实体颜色和渲染模式
void SafeSetEntityColor(int entity, int r, int g, int b, int a)
{
    if (!CheckEntitybyName(entity))
        return;
        
    // 检查实体是否支持渲染属性
    if (!HasEntProp(entity, Prop_Send, "m_nRenderMode"))
        return;
    
    // 先设置渲染模式，确保颜色能正确显示
    SetEntProp(entity, Prop_Send, "m_nRenderMode", 1); // kRenderTransColor
    
    // 安全地设置颜色
    if (HasEntProp(entity, Prop_Send, "m_clrRender"))
        SetEntityRenderColor(entity, r, g, b, a);
    
    // 确保实体可见
    if (HasEntProp(entity, Prop_Send, "m_fEffects"))
        SetEntProp(entity, Prop_Send, "m_fEffects", GetEntProp(entity, Prop_Send, "m_fEffects") & ~32); // 移除EF_NODRAW
    
    // 为门实体创建轮廓效果
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

    // 特殊处理救援点实体
    if (StrEqual(entityClassname, "info_survivor_rescue"))
        strcopy(modelName, sizeof(modelName), "models/props_unique/airport/atlas_break_ball.mdl");
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

    // 如果是info_survivor_rescue实体，在生成后设置模型缩放
    if (StrEqual(entityClassname, "info_survivor_rescue"))
        SetEntPropFloat(outlineEntity, Prop_Send, "m_flModelScale", 0.15); // 缩放为15%大小
    
    // 获取原实体的位置和角度
    float pos[3], angles[3];
    GetEntPropVector(entity, Prop_Send, "m_vecOrigin", pos);
    GetEntPropVector(entity, Prop_Send, "m_angRotation", angles);

    // 如果是info_survivor_rescue实体，调整Z轴坐标下移20个单位
    if (StrEqual(entityClassname, "info_survivor_rescue"))
        pos[2] -= 20.0; // Z轴坐标下移20个单位
    
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
    // 获取参考实体的位置
    float refPos[3];
    if (i >= 1 && i <= MaxClients)
        GetClientAbsOrigin(i, refPos);
    else
        GetEntPropVector(i, Prop_Send, "m_vecOrigin", refPos);

    int nearestEntity = -1;
    float minDistance = -1.0;

    // 遍历所有实体
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, targetClassname)) != -1)
    {
        if (entity == i) continue;
        
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

// 基于导航网格的“路径连通”检查（BFS，最多展开 maxDepth 层）
// 只沿着具有 NAV_MESH_RESCUE_CLOSET 属性的导航区域进行扩展；
// 若能在 maxDepth 内到达 doorPos 所在的导航区域，则视为连通。
bool IsPathConnectedRescueCloset(float vStartPos[3], float vGoalPos[3], int maxDepth)
{
    Address startArea = L4D_GetNearestNavArea(vStartPos, 220.0, true, false, false, 0);
    Address goalArea  = L4D_GetNearestNavArea(vGoalPos, 220.0, true, false, false, 0);

    if (startArea == Address_Null || goalArea == Address_Null)
        return false;

    if (startArea == goalArea)
        return true;

    // 获取全部导航区域并预筛，仅保留含 NAV_MESH_RESCUE_CLOSET 的区域
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

    // 目标区域若不在预筛集合中，则无法通过“rescuecloset”的路径到达
    bool goalAllowed = false;
    for (int gi = 0; gi < closetTotal; gi++)
    {
        if (closetAreas.Get(gi) == goalArea)
        {
            goalAllowed = true;
            break;
        }
    }
    if (!goalAllowed)
    {
        delete areas;
        delete closetAreas;
        return false;
    }

    // 访问标记（按 NavArea ID）
    ArrayList visited = new ArrayList();
    ArrayList queue   = new ArrayList();   // 存储 Address（可包含 startArea 以及 closetAreas 中的区域）
    ArrayList depths  = new ArrayList();   // 存储 int 深度

    // 起点入队
    queue.Push(startArea);
    depths.Push(0);
    visited.Push(L4D_GetNavAreaID(startArea));

    bool found = false;

    while (queue.Length > 0)
    {
        Address cur = queue.Get(0);
        int depth   = depths.Get(0);
        queue.Erase(0);
        depths.Erase(0);

        if (cur == goalArea)
        {
            found = true;
            break;
        }

        if (depth >= maxDepth)
            continue;

        // 只在预筛后的 closetAreas 集合内寻找邻接候选
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

            visited.Push(candId);
            queue.Push(cand);
            depths.Push(depth + 1);
        }
    }

    delete areas;
    delete closetAreas;
    delete visited;
    delete queue;
    delete depths;

    return found;
}

int FindRescueDoorEntity(int referenceEntity)
{
    // 目标：在以 refPos 为圆心、MAX_SEARCH_DIST 为半径内，
    // 查找最近的符合要求的门（标准救援门），并且其导航区域与 refPos 以rescuecloset路径连通；
    // 若最近者不连通，则继续找次近者，最终返回最近的“连通的救援门”；若没有则返回 -1。
    if (!IsValidEntity(referenceEntity)) return -1;

    float refPos[3];
    GetEntPropVector(referenceEntity, Prop_Send, "m_vecOrigin", refPos);

    int bestDoor = -1;
    float bestDist = -1.0;

    for (int i = 0; i < sizeof(g_DoorTypes); i++)
    {
        int ent = -1;
        while ((ent = FindEntityByClassname(ent, g_DoorTypes[i])) != -1)
        {
            if (ent == referenceEntity || !IsValidEntity(ent))
                continue;

            if(!IsRescueDoor(ent))
                continue;

            float doorPos[3];
            GetEntPropVector(ent, Prop_Send, "m_vecOrigin", doorPos);

            float distance = GetVectorDistance(refPos, doorPos);
            if (distance > float(MAX_SEARCH_DIST))
                continue;

            // 判断“路径连通”（BFS，最多10层）
            // 仅沿含 NAV_MESH_RESCUE_CLOSET 属性的导航区域进行扩展
            if (!IsPathConnectedRescueCloset(refPos, doorPos, 10))
                continue;

            if (bestDist < 0.0 || distance < bestDist)
            {
                bestDist = distance;
                bestDoor = ent;
            }
        }
    }

    return bestDoor;
}

// 添加门实体到闪烁列表，并记录关联次数
bool AddDoorWithCount(int doorEntity)
{
    if (doorEntity == -1) return false;
    
    // 检查门是否已经在闪烁列表中
    int doorIndex = g_aBlinkingDoors.FindValue(doorEntity);
    bool doorExists = (doorIndex != -1);
    
    // 如果门不在闪烁列表中，添加它
    if (!doorExists)
        g_aBlinkingDoors.Push(doorEntity);
    
    // 查找门实体在计数数组中的位置
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
    {
        // 门实体已存在，增加计数
        int doorCurrentCount = g_aDoorEntityCounts.Get(countIndex + 1);
        g_aDoorEntityCounts.Set(countIndex + 1, doorCurrentCount + 1);
    }
    else
    {
        // 门实体不存在，添加新记录
        g_aDoorEntityCounts.Push(doorEntity);
        g_aDoorEntityCounts.Push(1); // 初始计数为1
    }
    
    return !doorExists; // 返回是否是新添加的门
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
    if (!CheckEntitybyName(door))
        return;

    if (HasEntProp(door, Prop_Send, "m_clrRender"))
        SetEntityRenderColor(door, 255, 255, 255, 255);

    if (HasEntProp(door, Prop_Send, "m_nRenderMode"))
        SetEntProp(door, Prop_Send, "m_nRenderMode", 0); // kRenderNormal
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
    {
        EndDoorBlink(g_aBlinkingDoors.Get(i));
    }
    ClearDoorOutlines();
    g_aBlinkingDoors.Clear();
    g_aDoorEntityCounts.Clear();
    ClearRescuePoints();
}

bool CheckPosition(float pos[3], int navMask)
{
    Address area = L4D_GetNearestNavArea(pos, 220.0, true, false, false, 0); // 位置；搜索距离；忽略高度差距；检查视线；检查地面连接；类型

    if (area == Address_Null)
        return false;

    int attributes = L4D_GetNavArea_SpawnAttributes(area);

    // 是否包含指定的导航属性
    return (attributes & navMask) != 0;
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

    int entity = -1;
    int find_entity = -1;
    float origin[3];
    
    // 统计info_survivor_rescue实体总数
    while ((entity = FindEntityByClassname(entity, "info_survivor_rescue")) != -1)
    {
        g_iTotalRescuePoints++;
        GetEntPropVector(entity, Prop_Data, "m_vecOrigin", origin);
        find_entity = FindRescueDoorEntity(entity);
        if (find_entity != -1)
        {
            if (HasEntProp(find_entity, Prop_Send, "m_isRescueDoor") && GetEntProp(find_entity, Prop_Send, "m_isRescueDoor") == 1)
                // 标准救援门
                AddDoorWithCount(find_entity);
            else
                // 不正确关联的门实体，直接添加救援点实体
                AddRescuePointEntity(entity);
        }
        else
            // 没有找到任何类型的门
            AddRescuePointEntity(entity);
    }
    
    // 使用配置的闪烁速度
    float blinkSpeed = GetConVarFloat(g_hBlinkSpeed);
    g_hTimer = CreateTimer(blinkSpeed, Timer_DoorBlink, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

    for (int i = 0; i < g_aRescuePoints.Length; i++)
        CreateEntityOutline(g_aRescuePoints.Get(i), 0, 255, 0); // 绿色轮廓

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
            // 获取实体类名，确保只对指定的门类型进行闪烁
            if (!CheckEntitybyName(door))
                continue;
            
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
    CPrintToChatAll("{default}救援事件触发 本章节剩余复活门{lightgreen}%d{default}扇 剩余标记的救援点实体{lightgreen}%d{default}个", g_aBlinkingDoors.Length, g_aRescuePoints.Length);
    return Plugin_Continue;
}

public void Event_PlayerLeftSafeArea(Event event, const char[] name, bool dontBroadcast)
{
    CPrintToChatAll("{default}本章节共有复活门{lightgreen}%d{default}扇 救援点实体{lightgreen}%d{default}个 其中标记的救援点实体共有{lightgreen}%d{default}个", g_aBlinkingDoors.Length, g_iTotalRescuePoints, g_aRescuePoints.Length);
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
    if (FloatAbs(currentTime - g_fLastNotifyTime) >= 5.0)
    {
        ConVar rescuetimeCvar = FindConVar("rescue_min_dead_time");
        int rescueTime = (rescuetimeCvar != null) ? rescuetimeCvar.IntValue : 60;
        
        CPrintToChatAll("{default}本章节剩余复活门{lightgreen}%d{default}扇 剩余标记的救援点实体{lightgreen}%d{default}个 救援等待时间{lightgreen}%d{default}秒", 
                        g_aBlinkingDoors.Length, g_aRescuePoints.Length, rescueTime);
        
        g_fLastNotifyTime = currentTime;
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
        CPrintToChatAll("{default}复活门已被开启 本章节剩余复活门{lightgreen}%d{default}扇 剩余标记的救援点实体{lightgreen}%d{default}个", g_aBlinkingDoors.Length, g_aRescuePoints.Length);
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
    ClearAll();
}

public void Event_FinaleStart(Event event, const char[] name, bool dontBroadcast)
{
    ClearAll();
    
    CPrintToChatAll("{default}章节救援开始！所有复活门及救援实体已{lightgreen}失效");
}