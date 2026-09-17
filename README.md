# 🏝️ Limita

> **Dynamic Bezel AI Limits Tracker for macOS**  
> Нативное macOS приложение в стиле Dynamic Island для отслеживания 5-часовых и недельных лимитов **Codex (ChatGPT)** и **Claude**.

---

## ✨ Возможности

- **Скрытый режим (Dynamic Bezel)**: По умолчанию приложение не занимает места на экране и спрятано за верхней гранью дисплея.
- **Интерактивная пилюля (Hover Pill)**: При подведении курсора к верхнему краю плавно выезжает компактная пилюля с цветовыми индикаторами статуса:
  - 🟢 **Зелёный**: < 70% расхода
  - 🟡 **Оранжевый**: 70% – 90% расхода
  - 🔴 **Красный**: > 90% расхода
- **Развёрнутая панель (Expanded View)**: Клик по пилюле открывает детальное окно с визуальными прогресс-барами:
  - ⚡ **Codex**: 5-hour limit + weekly limit
  - 🤖 **Claude**: 5-hour limit + weekly limit
- **Фоновое автообновление**: Проверка и актуализация данных каждые 15 минут в фоне.
- **Однократная авторизация**: Встроенное изолированное окно входа с поддержкой OAuth (Google / Apple ID) и десктопным движком WebKit.
- **Menu Bar интеграция**: Иконка в строке меню для быстрого вызова логина, ручного обновления (`⌘R`) и выхода. Приложение не захламляет Dock (`LSUIElement = true`).

---

## 🛠️ Стек технологий

- **Язык**: Swift 5.9+
- **Интерфейс**: SwiftUI + AppKit (`NSPanel`, `.statusBar` level)
- **Платформа**: macOS 14.0 (Sonoma) и новее (Apple Silicon & Intel)
- **Сетевой движок**: WebKit (`WKWebView`, `WKWebsiteDataStore`) с поддержкой десктопных заголовков и асинхронного выполнения скриптов
- **Сборка**: Xcode / [XcodeGen](https://github.com/yonaskolb/XcodeGen)

---

## 🚀 Сборка и запуск

### Требования
- macOS 14.0+
- Xcode 15+

### Быстрый старт

1. Склонируйте репозиторий:
   ```bash
   git clone https://github.com/your-username/limita.git
   cd limita
   ```

2. Откройте проект в Xcode:
   ```bash
   open Limita.xcodeproj
   ```

3. Нажмите **Run (`⌘R`)**.

*(Опционально)* Если вы изменяете структуру файлов или конфигурацию проекта:
```bash
# Установка XcodeGen (если не установлен)
brew install xcodegen

# Регенерация проекта из project.yml
xcodegen generate
```

---

## ⚙️ Настройка при первом запуске

1. При первом запуске появится иконка ⊙ в строке меню (menu bar).
2. Нажмите на иконку в menu bar → **«Войти в Codex...»** и выполните вход в аккаунт OpenAI.
3. Повторите для **«Войти в Claude...»** (аккаунт Anthropic).
4. Сессия и куки сохраняются локально. Дальше приложение автоматически скрапит актуальные лимиты.
5. При запросе системы разрешите доступ в **Системные настройки → Конфиденциальность и безопасность → Мониторинг ввода (Input Monitoring)**, чтобы приложение могло отслеживать подведение курсора к верхнему краю экрана.

---

## 📂 Структура проекта

```
Limita/
├── App/
│   ├── LimitaApp.swift           # Точка входа SwiftUI (@main)
│   └── AppDelegate.swift         # Жизненный цикл, Menu Bar и окна логина
├── Models/
│   └── LimitData.swift           # Модели данных (ServiceLimit, ServiceStatus, Service)
├── Data/
│   ├── LimitsStore.swift         # @Observable хранилище состояния и таймер
│   ├── OpenAIScraper.swift       # WKWebView скрапер для ChatGPT / Codex
│   ├── ClaudeScraper.swift       # WKWebView скрапер для Claude.ai
│   └── LoginWebView.swift        # Окно авторизации с панелью навигации
├── UI/
│   ├── BezelPanelController.swift# Управление NSPanel оверлеем и hover-триггером
│   ├── MiniPillView.swift        # Компактный виджет пилюли при наведении
│   └── ExpandedView.swift        # Полная карточка со всеми лимитами
└── Info.plist                    # Конфигурация приложения (LSUIElement)
```

---

## 📄 Лицензия

MIT License. См. файл [LICENSE](LICENSE) для подробностей.
