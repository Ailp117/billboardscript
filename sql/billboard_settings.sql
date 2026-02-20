CREATE TABLE IF NOT EXISTS `billboard_settings` (
    `id` INT NOT NULL,
    `settings` LONGTEXT NOT NULL,
    `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO `billboard_settings` (`id`, `settings`)
SELECT 1, '{"enabled":true,"rotationSeconds":30,"urls":["https://picsum.photos/1920/1080?random=1001"]}'
WHERE NOT EXISTS (
    SELECT 1 FROM `billboard_settings` WHERE `id` = 1
);
