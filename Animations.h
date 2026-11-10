#import <Cocoa/Cocoa.h>

// Все прямоугольники здесь в координатах Cocoa (начало внизу слева главного экрана).

// Запись в файл ~/Library/Logs/Topbar.log (системный журнал прячет такие сообщения).
void TBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// Номер окна для Accessibility-элемента (0, если узнать не вышло).
CGWindowID WindowIDOfElement(AXUIElementRef window);

// Полоса рабочих столов в Mission Control (NSMinY — её нижний край).
// NSZeroRect, если её не видно или нет права «Универсальный доступ».
NSRect MissionControlSpacesStrip(void);
// Вызвать при открытии Mission Control: забывает найденный элемент.
void MissionControlReset(void);

// Ловит сворачивание окон ДО того, как оно случилось (жёлтая кнопка, Cmd+M, пункт меню «Свернуть»),
// закрывает системную анимацию вниз «замороженным» снимком экрана и проигрывает свой джинн вверх, к панели.
// Нужны права «Универсальный доступ» и «Запись экрана»; без них остаётся обычное системное сворачивание.
@interface MinimizeWatcher : NSObject
// Куда лететь окну, которое сворачивают (место, где появится его иконка на панели).
@property (copy) NSRect (^targetForNewIcon)(void);
// Прямоугольник самой панели: то, что выше её нижнего края, анимация не закрывает.
@property (copy) NSRect (^barFrame)(void);
// Окно свернули или анимация закончилась: панели пора обновиться.
@property (copy) void (^didChange)(void);
// Пока YES (например, открыт Mission Control), ничего не перехватываем.
@property (assign) BOOL suspended;
// Подписывается на окна этих приложений (можно вызывать часто).
- (void)watchApps:(NSArray<NSRunningApplication *> *)apps;
// Разворачивает свёрнутое окно с анимацией из иконки на панели.
- (void)restoreWindow:(AXUIElementRef)window app:(NSRunningApplication *)app fromIcon:(NSRect)icon;
@end
