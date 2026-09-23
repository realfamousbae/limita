# Limita

Нативный индикатор лимитов Codex и Claude Code для macOS. Приложение живёт в menu bar и открывает отдельную панель справа под строкой меню, не перекрывая вырез камеры.

## Что работает

- лимиты Codex за 5 часов и 7 дней из локальных session-логов Codex;
- лимиты Claude Code за 5 часов и 7 дней через официальный status-line JSON;
- процент использования и время до сброса каждого окна;
- признаки свежих, устаревших и недоступных данных;
- автоматическое обновление раз в минуту и ручное обновление;
- несколько мониторов и полноэкранные Space;
- полностью кастомный чёрный dashboard без стандартного SwiftUI Material;
- вызов только из menu bar — центральная зона камеры не используется.

Limita не использует закрытые web API, не хранит cookies и не просит логин/пароль.

## Требования

- macOS 14 или новее;
- Xcode 15 или новее для сборки;
- установленный Codex CLI и/или Claude Code.

## Сборка

```bash
swift test
xcodegen generate
xcodebuild -project Limita.xcodeproj -scheme Limita -configuration Debug build
```

Или откройте `Limita.xcodeproj` в Xcode и запустите схему `Limita`.

## Источники данных

### Codex

Дополнительная настройка не нужна. Limita ищет последние `rate_limits` в:

- `~/.codex/sessions/**/rollout-*.jsonl`;
- `~/.codex/archived_sessions/rollout-*.jsonl`.

Если данных ещё нет, запустите хотя бы одну сессию Codex. Limita читает файлы с конца и не загружает содержимое диалога в память целиком.

### Claude Code

Выберите в menu bar **«Подключить Claude Code…»** или нажмите кнопку в панели. Limita добавит в `~/.claude/settings.json` status-line command, который получает лимиты от Claude Code.

После подключения запустите или продолжите интерактивную сессию Claude Code. Данные появятся при первом обновлении status line.

Если status line уже настроена другим инструментом, Limita не перезаписывает её и сообщает об этом. Подключение не выполняется автоматически без действия пользователя.

## Приватность

Для Codex обрабатывается только объект `rate_limits` из последней подходящей записи. Для Claude из status-line JSON сохраняются только:

- `five_hour.used_percentage` и `five_hour.resets_at`;
- `seven_day.used_percentage` и `seven_day.resets_at`;
- локальное время получения.

Путь проекта, transcript, session ID, prompts, ответы и учётные данные не сохраняются. Кэш Claude находится в `~/Library/Application Support/Limita/claude-status.json`.

## Структура

```text
Limita/
├── App/       # жизненный цикл и menu bar
├── Data/      # локальные readers и Claude status-line capture
├── Models/    # окна лимитов и состояния источников
└── UI/        # Dynamic Bezel, pill и полная панель
Tests/
└── LimitaTests/
```

## Лицензия

MIT — см. [LICENSE](LICENSE).
