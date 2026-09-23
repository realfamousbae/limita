# Limita

Нативный индикатор лимитов Codex и Claude Code для macOS.

- **Пилюля по наведению**: задержите курсор у верхнего края любого экрана — появится компактная пилюля с процентами и цветными индикаторами. Клик по ней разворачивает полную панель, увод курсора — прячет.
- **Menu bar**: левый клик по иконке открывает/закрывает панель, правый — меню. Клик вне панели её закрывает.
- **Вырез камеры не трогается**: у выреза (плюс запас 80 pt с каждой стороны) пилюля не вызывается, и ни пилюля, ни панель туда не заезжают — эта зона оставлена другим приложениям.

## Что работает

- лимиты Codex за 5 часов и 7 дней из локальных session-логов Codex;
- лимиты Claude Code за 5 часов и 7 дней через официальный status-line JSON;
- процент использования и время до сброса каждого окна;
- признаки свежих, устаревших и недоступных данных;
- автоматическое обновление раз в минуту и ручное обновление;
- несколько мониторов и полноэкранные Space;
- полностью кастомный чёрный dashboard без стандартного SwiftUI Material;
- зелёный < 70 %, оранжевый 70–90 %, красный ≥ 90 %, жёлтый — устаревшие данные.

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

Или откройте `Limita.xcodeproj` в Xcode и запустите схему `Limita`. `Limita.xcodeproj` генерируется из `project.yml` — после добавления/удаления файлов запускайте `xcodegen generate`.

## Источники данных

### Codex

Дополнительная настройка не нужна. Limita ищет последние `rate_limits` в:

- `~/.codex/sessions/**/rollout-*.jsonl`;
- `~/.codex/archived_sessions/rollout-*.jsonl`.

Если данных ещё нет, запустите хотя бы одну сессию Codex. Limita читает файлы с конца и не загружает содержимое диалога в память целиком.

### Claude Code

Выберите в меню (правый клик по иконке) **«Подключить Claude Code…»** или нажмите **Connect** в панели. Limita пропишет себя как status-line command в `~/.claude/settings.json`; данные появятся после следующего ответа Claude Code.

- Если status line уже настроена, Limita её **оборачивает**: сохраняет лимиты и запускает вашу команду с тем же stdin, так что её вывод не меняется.
- Если своей status line нет, Limita выводит краткую строку вида `5h 12% · 7d 40%`.
- **«Отключить Claude Code»** в меню возвращает прежнюю status line. Перед первым изменением сохраняется копия `settings.json.limita-backup`.
- Если приложение перенесли, при запуске Limita сама обновляет путь в хуке. Подключайте Limita из `/Applications`: путь сборки из DerivedData исчезает после очистки.

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
