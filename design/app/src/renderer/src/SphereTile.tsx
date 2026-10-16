import { BrandMark, type Brand } from './brands';

// An Obysphere's picture: a rounded square (circles are people). Its own
// image, filling the square; a brand's mark on black; or, with neither, its
// name's first letter on black. large: the size it's picked at (making one).
export default function SphereTile({ name, brand, image, large = false }: { name?: string; brand?: Brand; image?: string; large?: boolean }) {
  return (
    <span className={`sphere-tile${large ? ' is-large' : ''}`}>
      {image ? <img src={image} alt="" />
        : brand ? <BrandMark brand={brand} size={large ? 34 : 15} />
        : <span className="sphere-tile-letter">{name?.trim()[0]?.toUpperCase() ?? ''}</span>}
    </span>
  );
}
