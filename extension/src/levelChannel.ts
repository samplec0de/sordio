/// Имена сообщений между главным миром страницы и content script.
///
/// Вынесены отдельно намеренно: content script живёт в изолированном мире и
/// не должен тянуть к себе сам замер — иначе сборщик вложил бы в него весь
/// `level.ts`, и тот запустился бы дважды, во втором мире вхолостую.
export const LEVEL_MESSAGE = 'sordio-level';
export const CONTROL_MESSAGE = 'sordio-level-control';
