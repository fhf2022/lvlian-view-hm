import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;

  private updateAvoidArea(type: window.AvoidAreaType, area: window.AvoidArea): void {
    if (type === window.AvoidAreaType.TYPE_SYSTEM) {
      AppStorage.setOrCreate('statusBarHeightPx', area.topRect.height);
    } else if (type === window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR) {
      AppStorage.setOrCreate('navigationBarHeightPx', area.bottomRect.height);
    }
  }

  private observeAvoidAreas(win: window.Window): void {
    AppStorage.setOrCreate('statusBarHeightPx', 0);
    AppStorage.setOrCreate('navigationBarHeightPx', 0);
    try {
      this.updateAvoidArea(window.AvoidAreaType.TYPE_SYSTEM,
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM));
      this.updateAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR,
        win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR));
      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        this.updateAvoidArea(data.type, data.area);
      });
    } catch (err) {
      hilog.error(DOMAIN, 'EntryAbility', 'Failed to observe avoid areas: %{public}s', JSON.stringify(err));
    }
  }

  private applySystemBars(win: window.Window, colorMode: ConfigurationConstant.ColorMode): void {
    const isDark = colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('isDarkTheme', isDark);
    win.setWindowSystemBarProperties({
      // 透明系统栏必须和应用背景统一，否则上下会出现明显色带。
      statusBarColor: '#00FFFFFF',
      navigationBarColor: '#00FFFFFF',
      statusBarContentColor: isDark ? '#FFFFFFFF' : '#FF172033',
      navigationBarContentColor: isDark ? '#FFFFFFFF' : '#FF172033'
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'EntryAbility', 'Failed to apply system bars: %{public}s', JSON.stringify(err));
    });
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('abilityInBackground', false);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    windowStage.getMainWindow().then((win: window.Window) => {
      this.mainWindow = win;
      win.setWindowLayoutFullScreen(true).then(() => {
        this.observeAvoidAreas(win);
        hilog.info(DOMAIN, 'EntryAbility', '%{public}s', 'Full screen layout enabled');
      }).catch((err: Error) => {
        this.observeAvoidAreas(win);
        hilog.error(DOMAIN, 'EntryAbility', 'Failed to set full screen: %{public}s', JSON.stringify(err));
      });
      this.applySystemBars(win, this.context.config.colorMode ?? ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    }).catch((err: Error) => {
      hilog.error(DOMAIN, 'EntryAbility', 'Failed to get main window: %{public}s', JSON.stringify(err));
    });

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    this.mainWindow = null;
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    if (this.mainWindow !== null && newConfig.colorMode !== undefined) {
      this.applySystemBars(this.mainWindow, newConfig.colorMode);
    }
  }

  onForeground(): void {
    // Ability has brought to foreground
    AppStorage.setOrCreate('abilityInBackground', false);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    AppStorage.setOrCreate('abilityInBackground', true);
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}
