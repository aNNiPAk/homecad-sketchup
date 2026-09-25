# HomeCAD for SketchUp

## Цель

Создать open-source репозиторий для управления SketchUp через MCP, ориентированный не на низкоуровневое рисование примитивов, а на проектирование жилой квартиры.

Основные сценарии:

1. Планировка квартиры.
2. Стены, комнаты, двери, окна, ниши.
3. Корпусная мебель.
4. Кухонные гарнитуры.
5. Электрика.
6. Освещение и LED.
7. Измерения и проверки.
8. Визуальная проверка результата через viewport screenshots.
9. Возможность использовать низкоуровневый SketchUp Ruby API как fallback.

Главный пользовательский интерфейс — естественный язык через Codex.

Пример конечного запроса:

> Вдоль правой стены кухни поставь нижний ряд кухни. Холодильник 600 мм, ПММ 600, мойка 600, варочная 600. Оставшееся место распредели между ящиками. Проверь пересечения с окном и дверью. Затем расставь розетки для техники и фартука и добавь LED-подсветку рабочей зоны. После изменений покажи план сверху и изометрию.

HomeCAD должен уметь разложить такую задачу на структурированные операции.

---

# 1. Основные архитектурные принципы

## 1.1 SketchUp является геометрическим движком

Не переносить полноценную CAD-геометрию в Python.

Основная геометрия создаётся через официальный SketchUp Ruby API внутри SketchUp.

Архитектура:

```text
Codex
  ↓ MCP stdio
Python MCP server
  ↓ local transport
SketchUp Ruby extension
  ↓
SketchUp Ruby API
  ↓
SketchUp model
```

Python отвечает за:

- MCP interface;
- JSON schemas;
- validation запросов;
- соединение;
- обработку timeout/reconnect;
- преобразование MCP responses.

Ruby отвечает за:

- доступ к SketchUp;
- создание геометрии;
- изменение модели;
- получение данных;
- transactions / Undo;
- screenshots;
- хранение HomeCAD metadata.

---

# 2. Единицы измерения

Публичное HomeCAD API использует:

```text
длины: millimeters
углы: degrees
площадь: square millimeters
мощность: watts
напряжение: volts
цветовая температура: kelvin
```

SketchUp Ruby API использует внутренние Length.

Все преобразования должны происходить централизованно внутри Ruby-слоя.

Никогда не принимать SketchUp internal inches через публичный MCP API.

Создать:

```text
Units.mm_to_internal()
Units.internal_to_mm()
```

Не дублировать конверсию в отдельных tools.

---

# 3. Идентификация объектов

Нельзя строить систему только вокруг `entityID`.

Каждый HomeCAD object получает собственный стабильный UUID.

Пример:

```json
{
  "homecad_id": "01JABC...",
  "type": "wall",
  "schema_version": 1,
  "revision": 3
}
```

Metadata хранится через SketchUp AttributeDictionary:

```text
dictionary = "HomeCAD"
```

Для объекта сохранять:

```text
homecad_id
type
schema_version
revision
generated
parent_id
```

Дополнительно возвращать:

```text
persistent_id
entity_id
```

Приоритет идентификации:

```text
homecad_id
→ persistent_id
→ entity_id
```

---

# 4. Транзакции

Каждый mutating MCP call должен соответствовать ровно одному SketchUp Undo.

Все изменения выполнять через единый helper:

```ruby
HomeCAD::Operation.run("Create Wall") do
  ...
end
```

Логика:

```text
start_operation
try
    modification
    commit_operation
catch
    abort_operation
    raise
```

Не создавать вложенные operations.

---

# 5. Ответ каждого mutating tool

Не возвращать только `"success": true`.

Возвращать структурированный ответ.

Пример:

```json
{
  "status": "success",
  "operation": "create_wall",
  "created": [
    {
      "homecad_id": "...",
      "type": "wall"
    }
  ],
  "updated": [],
  "deleted": [],
  "warnings": [],
  "revision": 17
}
```

Ошибки разделять на:

```text
invalid_request
target_not_found
ambiguous_target
geometry_error
constraint_violation
unsupported_operation
internal_error
```

---

# 6. Репозиторий

Создать структуру:

```text
homecad-sketchup/
│
├── README.md
├── AGENTS.md
├── IMPLEMENTATION_PLAN.md
├── CHANGELOG.md
├── LICENSE
│
├── mcp/
│   ├── pyproject.toml
│   └── homecad_mcp/
│       ├── server.py
│       ├── connection.py
│       ├── config.py
│       ├── errors.py
│       ├── schemas/
│       │
│       └── tools/
│           ├── system.py
│           ├── scene.py
│           ├── architecture.py
│           ├── furniture.py
│           ├── kitchen.py
│           ├── electrical.py
│           ├── lighting.py
│           ├── validation.py
│           └── developer.py
│
├── sketchup/
│   ├── homecad.rb
│   └── homecad/
│       ├── main.rb
│       │
│       ├── runtime/
│       │   ├── server.rb
│       │   ├── dispatcher.rb
│       │   └── operation.rb
│       │
│       ├── core/
│       │   ├── units.rb
│       │   ├── ids.rb
│       │   ├── metadata.rb
│       │   ├── targeting.rb
│       │   └── serializer.rb
│       │
│       ├── scene/
│       ├── architecture/
│       ├── furniture/
│       ├── kitchen/
│       ├── electrical/
│       ├── lighting/
│       ├── validation/
│       └── view/
│
├── tests/
│   ├── python/
│   ├── ruby/
│   ├── contracts/
│   └── e2e/
│
└── examples/
```

---

# 7. Этап 0 — bootstrap

Цель:

получить минимальное надёжное соединение Codex → MCP → SketchUp.

Реализовать только:

```text
homecad_status
get_model_info
```

`homecad_status` должен возвращать:

```text
MCP version
Ruby extension version
SketchUp version
model name
connection status
protocol version
```

Добавить version handshake между Python и Ruby.

Acceptance criteria:

```text
1. MCP server запускается.
2. SketchUp extension запускается.
3. Codex вызывает homecad_status.
4. При отсутствии SketchUp получается понятная ошибка.
5. При несовместимой версии bridge получается понятная ошибка.
6. Есть unit tests transport слоя.
```

До выполнения этих условий не переходить к следующим этапам.

---

# 8. Этап 1 — Scene Inspection

Реализовать:

```text
list_objects
find_objects
get_object
get_selection
measure
capture_view
undo
```

## find_objects

Поддержать поиск по:

```text
homecad_id
persistent_id
entity_id
type
name
room_id
parent_id
metadata
```

Поиск должен возвращать:

```text
none
unique
ambiguous
multiple
```

Не выбирать случайно один объект при неоднозначности.

## get_object

Возвращать:

```text
identity
type
name
metadata
bbox_mm
bbox_dimensions_mm
transformation
parent
children
material
tag
visibility
```

## capture_view

Поддержать:

```text
current
top
front
back
left
right
iso
```

Параметры:

```text
zoom_extents
target_homecad_id
restore_camera
max_size
```

Codex должен иметь возможность:

```text
изменить объект
→ получить screenshot
→ визуально проверить результат
```

---

# 9. Этап 2 — Primitive Geometry

**Статус: реализован в версии 0.4.0.** Контракт и ограничения зафиксированы в [tests/contracts/m2.md](tests/contracts/m2.md) и [docs/M2_DECISIONS.md](docs/M2_DECISIONS.md). Следующий milestone M3 не входит в текущую реализацию.

Добавить fallback tools:

```text
create_group
create_face
create_edge
create_box
create_circle
create_arc
create_polygon
push_pull
follow_me
transform_object
boolean_operation
```

Все размеры — mm.

Все создаваемые Groups автоматически получают HomeCAD metadata.

Primitive geometry не должна становиться основным интерфейсом HomeCAD.

Она используется для:

```text
нестандартной геометрии
прототипирования
developer workflows
```

---

# 10. Этап 3 — Architecture

Создать domain objects:

```text
Apartment
Room
Wall
Opening
Door
Window
Column
Niche
```

## Wall

Параметры:

```text
start
end
thickness_mm
height_mm
```

Wall определяет локальную систему координат:

```text
U = вдоль стены
V = наружу/внутрь стены
Z = вертикаль
```

Связанные объекты должны позиционироваться относительно Wall, а не мировых XYZ.

MCP tools:

```text
create_wall
update_wall
delete_wall

create_opening
create_door
create_window

create_room
detect_rooms
```

---

# 11. Wall attachment model

Создать универсальную структуру:

```json
{
  "wall_id": "...",
  "offset_mm": 1500,
  "height_mm": 300,
  "depth_offset_mm": 0,
  "side": "room"
}
```

Использовать её для:

```text
шкафов
розеток
выключателей
бра
LED
радиаторов
прочих настенных объектов
```

При изменении геометрии стены прикреплённые объекты должны иметь возможность перестроиться.

---

# 12. Этап 4 — базовая мебель

Domain objects:

```text
Furniture
Cabinet
Panel
Shelf
Front
Drawer
Wardrobe
```

Первый основной tool:

```text
create_cabinet
```

Параметры:

```text
width_mm
height_mm
depth_mm

carcass_mm
back_mm
front_thickness_mm
front_gap_mm

shelves
drawers

plinth_height_mm
material
front_material
```

Поддержать:

```text
concept LOD
manufacturing LOD
```

## concept

Создавать только:

```text
общий корпус
фасады
```

## manufacturing

Создавать:

```text
left_panel
right_panel
bottom
top
shelves
back
fronts
drawers
plinth
```

Каждая деталь должна быть отдельным HomeCAD child object.

---

# 13. Параметрическое обновление мебели

Не редактировать сгенерированную мебель вручную.

Реализовать:

```text
update_cabinet
regenerate_cabinet
```

Источником истины являются parameters, хранящиеся в metadata.

Алгоритм:

```text
read parameters
→ calculate parts
→ rebuild generated geometry
→ preserve HomeCAD cabinet identity
```

При перестроении child IDs желательно сохранять там, где это возможно.

---

# 14. Cutlist

Реализовать:

```text
generate_cutlist
```

Результат:

```text
part
quantity
length_mm
width_mm
thickness_mm
material
edge_band
cabinet_id
```

На первом этапе достаточно JSON/CSV.

Excel можно добавить позже.

---

# 15. Этап 5 — Kitchen

Создать domain:

```text
Kitchen
KitchenRun

BaseCabinet
WallCabinet
TallCabinet

Countertop
Filler
Plinth
Appliance
```

Типы modules:

```text
base_shelves
base_drawers
sink
hob
dishwasher
oven
tall_storage
fridge
wall_shelves
wall_lift_front
```

---

# 16. Kitchen planning

Разделить:

```text
plan_kitchen_run
apply_kitchen_run
```

`plan_kitchen_run` ничего не меняет в SketchUp.

Он принимает:

```text
wall
available range
start clearance
end clearance
modules
constraints
```

И возвращает:

```text
planned positions
remaining space
fillers
warnings
conflicts
```

Только после проверки пользователь/агент вызывает:

```text
apply_kitchen_run
```

---

# 17. Kitchen validation

Реализовать:

```text
validate_kitchen
```

Минимальные проверки:

```text
cabinet collision
cabinet outside wall range
door collision
window collision
opening collision
appliance collision
negative filler
countertop missing coverage
wall cabinet collision
```

Позже:

```text
drawer opening
door swing
worktop ergonomic constraints
appliance service zones
```

---

# 18. Этап 6 — Electrical

Создать объекты:

```text
ElectricalPoint
Outlet
Switch
JunctionBox
Circuit
CableRoute
DistributionPanel
Consumer
```

## Outlet

Хранить:

```text
wall_id
offset_mm
height_mm
type
quantity
circuit_id
consumer_id
```

Tools:

```text
create_outlet
create_switch
create_electrical_point
update_electrical_point

create_circuit
assign_to_circuit

create_cable_route
```

---

# 19. Электрические потребители

Кухонные appliances должны иметь requirements.

Пример:

```json
{
  "type": "dishwasher",
  "electrical": {
    "required": true,
    "supply": "230V",
    "connection": "outlet"
  }
}
```

Реализовать:

```text
find_unpowered_consumers
```

Он должен находить:

```text
техника существует
но соответствующей electrical point нет
```

---

# 20. Нормативные правила

Не хардкодить все нормативы в domain logic.

Добавить:

```text
rulesets/
```

Например:

```text
generic
RU
EU
custom
```

Ruleset отвечает за проверки.

Domain objects остаются независимыми от страны.

---

# 21. Этап 7 — Lighting

Создать:

```text
LightFixture
Track
LEDProfile
LEDStrip
Driver
Dimmer
Controller
PowerFeed
```

## LEDStrip

Параметры:

```text
voltage_v
power_w_per_m
length_mm
cct_k
cri
dimming
```

Автоматически считать:

```text
power_w
```

## Driver

Хранить:

```text
voltage_v
rated_power_w
location
accessible
```

Реализовать:

```text
validate_led_system
```

Проверять:

```text
voltage match
driver load
driver reserve
missing driver
inaccessible driver
```

---

# 22. Этап 8 — General Validation

Создать:

```text
check_collisions
validate_project
```

`validate_project` вызывает capability-specific validators.

Ответ:

```json
{
  "errors": [],
  "warnings": [],
  "info": []
}
```

Каждая проблема содержит:

```text
code
message
affected_objects
severity
suggested_action
```

---

# 23. Этап 9 — Planning tools

Для опасных/массовых операций использовать двухфазную модель:

```text
plan_xxx
apply_xxx
```

Например:

```text
plan_kitchen_run
apply_kitchen_run

plan_electrical_layout
apply_electrical_layout
```

Planning tools являются read-only.

Они не должны менять SketchUp.

---

# 24. Этап 10 — Developer escape hatch

Только после появления стабильных domain tools добавить:

```text
eval_ruby
```

Он должен быть:

```text
disabled by default
localhost only
explicitly configurable
marked destructive / escape hatch
```

Codex instruction:

```text
Never use eval_ruby when a first-class HomeCAD tool can perform the task.
```

---

# 25. Tool annotations

Каждый MCP tool должен иметь корректную classification.

Пример:

```text
find_objects
readOnly = true

measure
readOnly = true

capture_view
readOnly = true

create_cabinet
readOnly = false

delete_object
destructive = true

eval_ruby
escape_hatch = true
```

---

# 26. Инструкции агенту

Создать `AGENTS.md`.

Основные правила Codex:

```text
1. Не изменяй модель без необходимости.
2. Сначала inspect.
3. Потом plan.
4. Потом mutate.
5. После mutate обязательно verify.
6. При сложной геометрии используй screenshot.
7. При неоднозначном target остановись.
8. Не угадывай object ID.
9. Не используй eval_ruby, если существует first-class tool.
10. Не редактируй generated cabinet geometry вручную.
11. Изменяй parameters и regenerate.
12. Каждая пользовательская операция должна быть Undo-able.
```

---

# 27. Типовой агентный цикл

Для любой существенной задачи:

```text
inspect
↓
identify targets
↓
measure
↓
plan
↓
apply
↓
structured validation
↓
capture screenshot
↓
final verification
```

Пример кухни:

```text
get room
↓
get wall
↓
measure wall
↓
find openings
↓
plan_kitchen_run
↓
inspect plan
↓
apply_kitchen_run
↓
validate_kitchen
↓
capture_view(top)
↓
capture_view(iso)
```

---

# 28. Тестирование

Три уровня.

## Python unit tests

Тестировать:

```text
schemas
validation
connection
protocol
timeouts
reconnect
error mapping
```

## Ruby unit tests

Тестировать без реального SketchUp там, где возможно:

```text
units
domain calculations
cabinet part calculation
kitchen layout
LED power calculation
validation rules
```

## E2E

Отдельный набор тестов против запущенного SketchUp.

Минимальный smoke test:

```text
connect
create room
create wall
create cabinet
move cabinet
create outlet
capture screenshot
validate
undo
verify removal
```

---

# 29. Golden test model

Создать тестовую квартиру.

Например:

```text
Apartment
├── Kitchen
├── LivingRoom
├── Bedroom
├── Hall
└── Bathroom
```

Использовать её для regression tests.

Изменения инструментария не должны ломать заранее известные:

```text
wall dimensions
cabinet positions
electrical points
validation results
```

---

# 30. Что НЕ делать в MVP

Не реализовывать сразу:

```text
BIM/IFC
фотореалистичный рендер
полную трассировку кабеля
полный электротехнический расчёт
расчёт нагрузок квартирного щита
водоснабжение
канализацию
отопление
параметрические лестницы
полный аналог Revit/Fusion
```

Сначала сделать узкую систему квартиры, кухни и электрики хорошо.

---

# 31. Приоритет реализации

P0:

```text
transport
status
units
metadata
targeting
transactions
tests
```

P1:

```text
scene inspection
measurement
screenshot
primitive geometry
```

P2:

```text
walls
rooms
openings
wall attachments
```

P3:

```text
cabinet
parametric regeneration
cutlist
```

P4:

```text
KitchenRun
countertop
appliances
kitchen validation
```

P5:

```text
outlets
switches
circuits
electrical validation
```

P6:

```text
LED
drivers
lighting validation
```

P7:

```text
advanced planning
rulesets
developer escape hatch
```

---

# 32. Правило работы Codex над репозиторием

Не реализовывать следующий milestone до завершения текущего.

Для каждого milestone:

```text
1. Изучить существующий код.
2. Написать краткий implementation plan.
3. Создать/обновить contracts.
4. Написать tests.
5. Реализовать Ruby layer.
6. Реализовать Python MCP layer.
7. Запустить unit tests.
8. Запустить integration tests.
9. Обновить docs.
10. Сделать один логически цельный commit.
```

Не создавать временную архитектуру, которую планируется сразу выбросить.

---

# 33. Первый конкретный milestone

Начать с `M0-bootstrap`.

Результат первого milestone должен содержать только:

```text
homecad_status
get_model_info
```

и инфраструктуру:

```text
Python MCP
Ruby SketchUp extension
TCP/JSON-RPC bridge
version handshake
logging
config
error handling
tests
RBZ packaging
```

Никаких стен, шкафов или электрики на этом этапе.

После M0 выполнить реальный smoke-test внутри SketchUp.

---

# 34. Второй milestone

`M1-scene-inspection`

Добавить:

```text
list_objects
find_objects
get_object
get_selection
measure
capture_view
undo
```

После этого проверить, что агент способен:

```text
открыть существующую SketchUp модель
найти объект
измерить его
получить screenshot
```

без `eval_ruby`.

---

# 35. Definition of Done проекта

HomeCAD считается достигшим первой полноценной версии, когда Codex способен выполнить E2E сценарий:

```text
1. Прочитать существующую планировку кухни.
2. Найти стену и проёмы.
3. Измерить доступную длину.
4. Спланировать кухонный ряд.
5. Создать параметрические шкафы.
6. Создать столешницу.
7. Добавить встроенную технику.
8. Создать электрические точки для техники.
9. Создать розетки фартука.
10. Создать LED-профиль и LED-ленту.
11. Назначить LED driver.
12. Проверить геометрические конфликты.
13. Проверить электрические связи.
14. Проверить LED power budget.
15. Получить вид сверху.
16. Получить изометрический screenshot.
17. Исправить найденные ошибки.
18. Повторно выполнить validation.
19. Сохранить модель.
20. Сгенерировать cutlist кухни.
```

При этом для нормального выполнения этого сценария `eval_ruby` использоваться не должен.
