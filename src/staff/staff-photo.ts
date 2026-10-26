import { BadRequestException } from '@nestjs/common';

export const MAX_PHOTO_BYTES = 2 * 1024 * 1024;

export type StaffPhotoUpload = {
  data: Buffer<ArrayBuffer>;
  mime: 'image/jpeg' | 'image/png';
};

const SIGNATURES: [StaffPhotoUpload['mime'], Buffer][] = [
  ['image/jpeg', Buffer.from([0xff, 0xd8, 0xff])],
  ['image/png', Buffer.from([0x89, 0x50, 0x4e, 0x47])],
];

export function parseStaffPhoto(data: Buffer<ArrayBuffer> | undefined): StaffPhotoUpload {
  if (!data?.length)
    throw new BadRequestException('Attach the photo in the "photo" form field');
  if (data.length > MAX_PHOTO_BYTES)
    throw new BadRequestException('Photo must be 2 MB or smaller');
  const match = SIGNATURES.find(([, signature]) =>
    data.subarray(0, signature.length).equals(signature),
  );
  if (!match)
    throw new BadRequestException('Photo must be a JPEG or PNG image');
  return { data, mime: match[0] };
}
